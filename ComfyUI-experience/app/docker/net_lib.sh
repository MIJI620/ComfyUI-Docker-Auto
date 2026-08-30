#!/bin/sh
# ============================================================================
# net_lib.sh —— ComfyUI-docker 内【所有网络源选择/下载判断】统一的库。
#
# 规则(全项目唯一, 任何网络下载不得再各自实现, 不得搞特例):
#   1. 判断一个"源"是否合法可用, 只看"能否真实从它那里拿到需要下载的文件"。
#      即对目标文件 URL 做真实网络嗅探: 响应码必须为 HTTP 200。
#   2. HTTP 3xx(重定向/302) 视为"该源自己并没有持有文件, 只是转发到别处"。
#      3xx 一律不算合法持源, 继续探测候选列表中的下一个源。
#      (例: mirror.sjtu.edu.cn/pytorch-wheels/cu130/* 会 302 转回
#       download.pytorch.org —— 那不代表交大自己持源, 不能选它。)
#   3. HTTP 4xx/5xx / 超时 / 网络不可达 均视为"该源未持有文件", 继续下一个。
#   4. 候选列表按"国内优先"排序, 官方源只作为列表最后一个兜底候选。
#      pick_first_200 从前往后真实嗅探, 绝不靠硬编码断定某个源可用或不可用。
#
# 用法(在构建层 source 本文件后调用):
#   PICK=$(pick_first_200 "相对路径1 相对路径2 ..." "<候选base1>" "<候选base2>" ...)
#     参数1 = 空格分隔的"需要全部存在"的相对路径(相对各候选 base), 全部 HTTP 200 才算该源合法持源;
#     其余   = 候选 base 列表。函数依次对每个 base 拼接完整 URL 做 HEAD 嗅探,
#     第一个"所有必需文件都返回 200"的 base 被 echo 到 stdout; 全部失败则 stdout 为空。
#     候选内可含官方源, 但须置于列表最后作为对底; 绝不硬编码优先官方。
#   构建层再据 PICK 决定用哪个源(pip --index-url / curl 下载)。
# ============================================================================

# 探测单个 URL 是否返回 HTTP 200。成功(200) echo 200; 否则 echo 实际码(或超时 000)。
# 超时可外部传入(环境变量), 以兼顾"默认别太激进"与"避免网络卡顿"两类需求:
#   NET_LIB_TOTAL_TIMEOUT   整体请求超时(秒), 默认 20  —— 需提速可在构建前 export 成更小值
#   NET_LIB_CONNECT_TIMEOUT TCP 建连超时(秒), 默认=整体超时; 连接卡死通常在此体现, 可单独调小
url_status() {
    t="${NET_LIB_TOTAL_TIMEOUT:-20}"
    c="${NET_LIB_CONNECT_TIMEOUT:-$t}"
    # -I 发 HEAD 请求: 只取响应头, 不下载正文体积(用于探测大 wheel 也又快又准)。
    # -s 静默  -o /dev/null 丢弃响应体  -w %{http_code} 只输出状态码
    # 不加 -L : 不跟随重定向, 以便把 3xx 当成"该源未持文件";
    #       (如 mirror.sjtu|aliyun 某些 3xx 是绕回外站, 不能算该源持有文件)
    curl -sI -o /dev/null -w '%{http_code}' --connect-timeout "$c" -m "$t" "$1" 2>/dev/null || echo 000
}

# 从候选源列表中选第一个"真实持有『全部所需』目标文件(HTTP 200)"的 base。
# 参数1 = 空格分隔的"需要全部存在"的相对路径列表(相对各候选 base);
#         只有全部路径在该 base 下都返回 HTTP 200 才算该源合法持源(避免只命中其一)。
# 其余   = 候选 base 列表(按国内优先排序, 官方源放最后作兜底)。
# 输出: 命中的 base 到 stdout; 若全失败 stdout 为空(stderr 打印排查信息)。
pick_first_200() {
    probe="$1"
    shift
    for base in "$@"; do
        ok=1
        for f in $probe; do
            code="$(url_status "${base%/}/$f")"
            if [ "$code" != "200" ]; then
                echo "  skip source: ${base%/}/$f  (http=$code)" >&2
                ok=0
                break
            fi
        done
        if [ "$ok" = "1" ]; then
            echo "$base"
            return 0
        fi
    done
    return 1
}

# ============================================================================
# pick_torch_source —— 为 torch/torchvision/torchaudio 选择"可用且反馈最快"的源,
# 并自动判断源类型:
#   - simple 索引(PEP503, 有 /torch/ 页用 <a href) => 可用 --index-url
#   - flat 目录(散装 .whl, 无 simple 页, 但 wheel 文件可达) => 只能精确用 wheel 文件 URL
#     直链安装(--find-links <目录URL> 无效: pip 要求该 URL 返回 HTML 目录列表才会扫, 否则报 versions:none)
# 选源依据 = 真实网络反馈(对 flat 候选做限量 Range 下载测速), 选最快的可用 flat;
#           一个 flat 都没有时才 fallback 到 simple(官方)兜底。
#
# 用法:
#   OUT="$(pick_torch_source "<w1> <w2> <w3>" "<simple_probe>" <samplesz> "<base1>" ...)"
#     参数1: 空格分隔的三个必需 wheel 文件名(flat 直链判定用)
#     参数2: simple 探针相对路径(通常 torch/)
#     参数3: 测速下载样本字节数(默认 2097152=2MB)
#     其余 : 候选 base(国内在前, 官方最后兜底)
# 输出(两行):
#   <simple|flat>
#   <base>
#   全不可用 => stdout 为空(调用方自行 fallback)。
# ============================================================================
pick_torch_source() {
    wheels="$1"; probe="$2"; samp="${3:-2097152}"; shift 3
    best_type=""; best=""; best_rate=0
    # 第一轮: 找可用 flat(三个 wheel 都能真实拿到, 跟随重定向), 并按下载速率选最快的
    for base in "$@"; do
        b="${base%/}"
        ok=1
        for f in $wheels; do
            # -L 跟随重定向 + Range 微小探测: 302/301(转发)只要真能拿到也算可用
            c="$(curl -sIL -r 0-0 -o /dev/null -w '%{http_code}' -m "${NET_LIB_TOTAL_TIMEOUT:-25}" "$b/$f" 2>/dev/null || echo 000)"
            case "$c" in
                200|206) : ;;
                *) echo "  skip(flat) source: $b/$f (http=$c)" >&2; ok=0; break ;;
            esac
        done
        if [ "$ok" = "1" ]; then
            # 限量 Range 下载测速(只取前 samp 字节, 不落盘), 以真实反馈选最快的
            out="$(curl -sL -r 0-$((samp-1)) -o /dev/null \
                 -m "${NET_LIB_TOTAL_TIMEOUT:-40}" \
                 -w '%{http_code} %{size_download} %{time_total}' "$b/$(echo $wheels | awk '{print $1}')" 2>/dev/null)"
            code="$(echo "$out" | awk '{print $1}')"
            sz="$(echo "$out" | awk '{print $2}')"
            t="$(echo "$out" | awk '{print $3}')"
            rate="$(echo "$t" | awk -v s="$sz" '{if($1>0) printf "%.0f", s/$1; else print 0}')"
            echo "  flat OK: $b  (range ${sz}B in ${t}s => ~${rate}B/s)" >&2
            if [ -z "$best_rate" ] || [ "$rate" -gt "$best_rate" ]; then
                best_type=flat; best="$b"; best_rate="$rate"
            fi
        fi
    done
    if [ -n "$best" ]; then
        echo "$best_type"; echo "$best"
        return 0
    fi
    # 第二轮: 无 flat 可用, fallback 到 simple(有 /torch/ 页且是 PEP503) 的一个
    for base in "$@"; do
        b="${base%/}"
        i="$(url_status "$b/$probe")"
        if [ "$i" = "200" ] && curl -s -m "${NET_LIB_TOTAL_TIMEOUT:-20}" "$b/$probe" 2>/dev/null | grep -q '<a href'; then
            echo "  simple OK: $b" >&2
            echo "simple"; echo "$b"
            return 0
        fi
    done
    return 1
}
