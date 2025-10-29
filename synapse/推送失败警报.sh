# 进入当前脚本所在目录
cd "$(dirname "$0")"

# 定义基于关键词的触发器
keyword="Error sending request to  POST https://matrix.org/_matrix/push/v1/notify"

# 目标容器名称
container_name=`cat ./constants.json | jq -r ".container_name"`

# ntfy 实例
ntfy_url=`cat ./constants.json | jq -r ".ntfy_url"`
ntfy_topic_name="synapse_log_based_triggers_39BED2DD5CAF"
curl -s -H "Title: Synapse 基于日志的触发器" -d "触发器已激活, 开始监控 Synapse 向 matrix.org/_matrix/push/v1/notify 的请求状况." "$ntfy_url/$ntfy_topic_name"

timeout $1 docker logs -tf --tail 1 $container_name 2>&1 | grep --line-buffered "$keyword" | \
while read line
do
  ntfy_topic_name="synapse_push_failure_warning_for_ios_1067C8A77671"
  curl_result=`curl -H "Priority: high" -H "Title: Synapse 推送警报 (matrix.org)" -d "失败原因: ${line:31}" "$ntfy_url/$ntfy_topic_name"`
  echo "[推送失败警报] $curl_result"
done
