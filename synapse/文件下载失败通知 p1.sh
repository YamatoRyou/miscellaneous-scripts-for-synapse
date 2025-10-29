# 脚本逻辑:
# 1. 用户尝试下载文件时
#  - 如果文件不存在, 则下载时向用户通知该文件已被删除
#    - 此次通知的 5 分钟内不重复通知
#    - 记录用户下载该文件时的 MXC ID 与时间戳, 并以时间戳为依据冷却通知

# 此脚本涉及到 Synapse 之外的数据库写入, 请确保以下变量中指定的数据库; 数据表及其相关的列存在, 并分配了合适的访问权限.
# 2025 / 05 / 09: 所需的数据库已通过 pgAdmin 手工创建.

# 进入当前脚本所在目录
cd "$(dirname "$0")"

# 定义基于关键词的触发器
keyword="404 \"GET /_matrix/client/v1/media/download" # 适用于下载已不存在或被隔离的文件
keyword2="?allow_redirect=true"

# 目标容器名称
container_name=`cat ./constants.json | jq -r ".container_name"`

# Synapse 实例
synapse_url=`cat ./constants.json | jq -r ".synapse_url"`
access_token=`cat ./constants.json | jq -r ".synapse_access_token"`

# ntfy 实例
ntfy_url=`cat ./constants.json | jq -r ".ntfy_url"`
ntfy_topic_name="synapse_log_based_triggers_39BED2DD5CAF"

curl -s -H "Title: Synapse 基于日志的触发器" -d "触发器已激活, 开始监控所有用户的文件下载失败 (不限大小)." "$ntfy_url/$ntfy_topic_name"

timeout $1 docker logs -tf --tail 1 $container_name 2>&1 | grep --line-buffered "$keyword" | \
while read line
do
  # 获取用户 ID
  target_userid=${line#*\{}
  target_userid=${target_userid%\}*}

  if [[ "$line" =~ "$keyword2" ]] # 新方法, 直接判断日志行中是否含有 $keyword2
  then
    # 获取媒体 MXC ID (含 ?allow_redirect=true 后缀, 针对旧版移动客户端及桌面 / Web 客户端)
    target_mxcid=${line#*dl.fuckcjmarketing.com\/}
    target_mxcid=${target_mxcid%\?*}
  else
    # 获取媒体 MXC ID (以空格结尾, 针对 Element X)
    target_mxcid=${line#*dl.fuckcjmarketing.com\/}
    target_mxcid=${target_mxcid%% *}
  fi

  echo "[文件下载失败通知] 监测到用户 $target_userid 下载文件 ($target_mxcid) 失败."
  # echo "[文件下载失败通知] 目标媒体 ID: $target_mxcid"
  
  # 在新进程中运行脚本, 并传递特定变量
  "./文件下载失败通知 p2.sh" "$target_userid" "$target_mxcid" &


done
