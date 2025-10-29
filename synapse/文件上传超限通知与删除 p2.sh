# 进入当前脚本所在目录
cd "$(dirname "$0")"

# 定义关键词
keyword="Stored local media in file "

# 临时目录
#tmp_path="/tmp/{251792DA-C8DB-77D8-0AA5-B58ED6B94C90}"
tmp_path=`cat ../tmp_storage_path.json | jq -r ".tmp_storage_path"`

# 目标容器名称
container_name=`cat ./constants.json | jq -r ".container_name"`

# ntfy 实例
ntfy_url=`cat ./constants.json | jq -r ".ntfy_url"`
ntfy_topic_name="synapse_log_based_triggers_39BED2DD5CAF"

curl -s -H "Title: Synapse 基于日志的触发器" -d "(文件上传超限通知与删除 P2) 触发器已激活." "$ntfy_url/$ntfy_topic_name"

timeout $1 docker logs -tf --tail 1 $container_name 2>&1 | grep --line-buffered "$keyword" | \
while read line
do
  # 取出 POST ID
  post_id="${line#*INFO - }"
  post_id="${post_id% - S*}"
  
  echo "[文件上传超限通知与删除 P2] 监测到关键字: $keyword, POST ID 为 $post_id"

  # 从日志条目中提取出相对文件路径
  filepath_postfix="${line#*Stored\ local\ media\ in\ file\ \'\/data/media_store}" # 去除左侧多余字符串
  filepath_postfix="${filepath_postfix%\'*}" # 去除右侧多余符号
  # filepath_postfix="$(echo ${filepath_postfix} | sed "s/\///g")" # 去除所有正斜杠
  echo "[文件上传超限通知与删除 P2] 相对文件路径: $filepath_postfix"

  # 创建命名管道
  # 由于上传任何文件 (包括不被 Synapse 视为已超限的文件) 日志中都会出现 $keyword, 因此先循环判断 $post_id-1 是否存在, 如果是则创建
  info_filepath1="$tmp_path/$post_id-1"

  until [ -e $info_filepath1 ]
  do
    # echo "[文件上传超限通知与删除 P2] 所需的命名管道 $info_filepath1 不存在, 继续监测..."
    echo "[文件上传超限通知与删除 P2] 已找到标识符为 $post_id-1 的命名管道."
  
    info_filepath2="$tmp_path/${post_id}-2"
    mkfifo $info_filepath2
    echo "[文件上传超限通知与删除 P2] 创建命名管道 (mkfifo 结果: $?): $info_filepath2"

    # 在上一步创建的命名管道中写入内容 (非阻塞)
    echo "[文件上传超限通知与删除 P2] 写入相对文件路径到命名管道: $info_filepath2"
    printf "$filepath_postfix" > $info_filepath2 &
    break
  done
done
