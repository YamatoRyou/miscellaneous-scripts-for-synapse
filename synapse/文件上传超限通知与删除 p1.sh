# 进入当前脚本所在目录
cd "$(dirname "$0")"

# 定义关键词
keyword="SynapseError: 400 - Media upload limit exceeded"

# 临时目录
#tmp_path="/tmp/{251792DA-C8DB-77D8-0AA5-B58ED6B94C90}"
tmp_path=`cat ../tmp_storage_path.json | jq -r ".tmp_storage_path"`

# 目标容器名称
container_name=`cat ./constants.json | jq -r ".container_name"`

# ntfy 实例
ntfy_url=`cat ./constants.json | jq -r ".ntfy_url"`
ntfy_topic_name="synapse_log_based_triggers_39BED2DD5CAF"

curl -s -H "Title: Synapse 基于日志的触发器" -d "(文件上传超限通知与删除 P1) 触发器已激活." "$ntfy_url/$ntfy_topic_name"

# 尝试创建 Ramdisk, 用于存储临时文件
#if [ ! -d "${tmp_path}" ]
#then
#  mkdir "${tmp_path}"
#  mount -t tmpfs -o size=1M tmpfs $tmp_path
#  echo "[文件上传超限通知与删除 P1] 已创建 Ramdisk (大小 1 MB), 目录 ${tmp_path}."
#else
#  echo "[文件上传超限通知与删除 P1] Ramdisk ${tmp_path} 已存在."
#fi

timeout $1 docker logs -tf --tail 1 $container_name 2>&1 | grep --line-buffered "$keyword" | \
while read line
do

  # 取出 POST ID
  post_id="${line#*INFO - }"
  post_id="${post_id% - <*}"
  
  echo "[文件上传超限通知与删除 P1] 监测到关键字: $keyword, POST ID 为 $post_id"

  # 创建命名管道
  info_filepath="$tmp_path/$post_id-1"
  mkfifo $info_filepath
  echo "[文件上传超限通知与删除 P1] 创建命名管道 (mkfifo 结果: $?): $info_filepath"

done
