# 进入当前脚本所在目录
cd "$(dirname "$0")"

# 定义基于关键词的触发器
keyword="Uploaded content with URI"

# 目标容器名称
container_name=`cat ./constants.json | jq -r ".container_name"`

# ntfy 实例
ntfy_url=`cat ./constants.json | jq -r ".ntfy_url"`
ntfy_topic_name="synapse_log_based_triggers_39BED2DD5CAF"

curl -s -H "Title: Synapse 基于日志的触发器" -d "触发器已激活, 开始监控所有用户的文件上传 (大于 5 MB)." "$ntfy_url/$ntfy_topic_name"

timeout $1 docker logs -tf --tail 1 $container_name 2>&1 | grep --line-buffered "$keyword" | \
while read line
do
#  echo "$line" | grep -E "$keyword" # 允许 grep 做正则匹配
#  if [ $? = 0 ]
#  if [[ "$line" =~ "$keyword" ]]
#  then
    # 获取上传的文件的 MXC ID
    target_mxcid=${line#*dl.fuckcjmarketing.com\/}
    target_mxcid=${target_mxcid%\'}
    
    echo "[文件上传成功通知 P1] 监测到文件 (媒体) 上传, MXC ID: $target_mxcid"

    # 在新进程中运行以下脚本, 并传递特定变量
    "./文件上传成功通知 p2.sh" "$target_mxcid" &
#  fi

done

# 已知问题
# 1. Element X for Android 无论是否上传文件到加密房间, 始终不在 Synapse 日志中显示文件名 (/_matrix/media/v3/upload 没有带上 filename 参数), 可能为缺陷.
# 2. 短时间内突发上传大量小文件会导致通知中的文件名与实际上传的文件名不对应. 原因可能在于 Synapse 日志无法及时刷新. 监控另一关键词 "Uploaded content with URI 'mxc://<服务器名称>/<媒体 MXC ID>'" 并从数据库中查询可能为更靠谱的解决方法.