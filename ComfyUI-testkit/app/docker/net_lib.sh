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
