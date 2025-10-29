# 文件大小门槛
filesize_limit=`cat ./constants.json | jq -r ".filesize_limit"` # 文件大小第一上限 5 MB (5242880 字节)
filesize_limit2=`cat ./constants.json | jq -r ".filesize_limit2"` # 文件大小第二上限 25 MB (26214400 字节)

# Synapse 实例
synapse_url=`cat ./constants.json | jq -r ".synapse_url"`
access_token=`cat ./constants.json | jq -r ".synapse_access_token"`
synapse_server_name=`cat ./constants.json | jq -r ".synapse_server_name"`

# Postgres 数据库连接信息 (新)
postgres_container_name=`cat ./constants.json | jq -r ".database.container_name"` # 容器名称
postgres_database_port=`cat ./constants.json | jq -r ".database.postgres_database_port"` # 数据库端口
postgres_database_name=`cat ./constants.json | jq -r ".database.postgres_database_name"` # 数据库名称
postgres_database_operator_name=`cat ./constants.json | jq -r ".database.postgres_database_operator_name"` # 操作数据库使用的用户名
postgres_database_table_name="local_media_repository" # 目标数据库中的目标表名称

# 获取要下载的文件信息 
media_info_json=`curl -X GET \
  -H "authorization: Bearer $access_token" \
  "$synapse_url/_synapse/admin/v1/media/$synapse_server_name/$2" | jq .`

# 获取要下载的文件大小 (字节)
target_media_size_bytes=`echo $media_info_json | jq -r ".media_info.media_length"`

# 获取要下载的文件上传时间戳 (13 位)
target_media_upload_timestamp13=`echo $media_info_json | jq -r ".media_info.created_ts"`
target_media_upload_timestamp10=(${target_media_upload_timestamp13:0:10}) # 转换为 10 位时间戳

# 获取要下载的文件名
target_media_filename_preload=`echo $media_info_json | jq -r ".media_info.upload_name"` # 预检
if [ "$target_media_filename_preload" == "null" ] # 如果下载的媒体不含文件名
then
  target_media_filename_urldecoded="未知"
else
  urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }
  target_media_filename_urldecoded=`urldecode $target_media_filename_preload`
  target_media_filename_urldecoded=`urldecode $target_media_filename_urldecoded` # 需要二次解码, 原因不明
fi

# 根据文件大小确定其距今有效期限
if [ $target_media_size_bytes -gt $filesize_limit -a $target_media_size_bytes -le $filesize_limit2 ]; # 如果文件大小大于 5 MB (5242880 字节) 且小于等于 25 MB (26214400 字节), 按距今 365 天 (8760 小时) 计算
then
  target_media_expire_timestamp10=`expr $target_media_upload_timestamp10 + 31536000`
elif [ $target_media_size_bytes -gt $filesize_limit2 ]; # 如果文件大小大于 25 MB (26214401 字节), 按距今 7 天 (168 小时) 计算
then
  target_media_expire_timestamp10=`expr $target_media_upload_timestamp10 + 604800` 
fi

# 计算当前时间戳 (10 位)
current_timestamp10=`date +%s`

# 计算剩余有效期 (10 位时间戳)
timestamp_diff10=`expr $target_media_expire_timestamp10 - $current_timestamp10`

# 转换时间戳的差为小时
timestamp_diff10_to_hours=`expr $timestamp_diff10 / 60 / 60`

# 只有要下载的文件同时满足以下条件时才发送通知
# - 文件大于规定的大小
# - 文件对应的 MXC ID 通知大于指定的冷却时间
if [ $target_media_size_bytes -gt $filesize_limit ]; # > 5 MB
then
  # 切换数据库
  postgres_database_name=`cat ./constants.json | jq -r ".database.postgres_database_name2"` # 数据库名称
  postgres_database_table_name="media_download_alert_cooldown_new" # 目标数据库中的目标表名称

  # 获取指定媒体 ID 在数据库中是否存在 (区分下载者用户 ID)
  is_exist=`docker exec $postgres_container_name psql -X -A -d $postgres_database_name -U $postgres_database_operator_name -p $postgres_database_port -t -c \
  "\
  SELECT EXISTS (
    SELECT
      latest_alert_ts10
    FROM
      $postgres_database_table_name
    WHERE
      media_id = '$2'
      AND
      user_id = '$1'); \
  "`

  echo "[文件下载成功通知 P2] 该条目在数据库中是否存在: $is_exist"

  if [ $is_exist = "t" ]; # t = 是, f = 否
  then
    # 获取指定媒体 ID 在数据库中最后一次记录的时间戳 (区分下载者用户 ID)
    latest_alert_ts10=`docker exec $postgres_container_name psql -X -A -d $postgres_database_name -U $postgres_database_operator_name -p $postgres_database_port -t -c \
    "\
    SELECT
      latest_alert_ts10
    FROM
      $postgres_database_table_name
    WHERE
      media_id = '$2'
      AND
      user_id = '$1'; \
    "`
    
    echo "[文件下载成功通知 P2] 当前时间戳 (10 位): $latest_alert_ts10"
    
    # 冷却时间 30 分钟 (1800 秒)
    cooldown_time=1800
    
    # 判断以上时间戳距今是否小于指定的冷却时间
    # 此变量仅用于计算以上时间戳
    timestamp_diff10_2=`expr $current_timestamp10 - $latest_alert_ts10`
    
    if [ $timestamp_diff10_2 -lt $cooldown_time ];
    then
      echo "[文件下载成功通知 P2] 冷却时间不足 30 分钟, 跳过记录时间戳."
    else
      echo "[文件下载成功通知 P2] 冷却时间已超过 30 分钟, 恢复记录时间戳."
      # 新增条目时区分下载者用户 ID
      result=`docker exec $postgres_container_name psql -X -A -d $postgres_database_name -U $postgres_database_operator_name -p $postgres_database_port -t -c \
      "\
      INSERT INTO $postgres_database_table_name (
        media_id,
        user_id,
        latest_alert_ts10
      )
      VALUES (
        '$2',
        '$1',
        $current_timestamp10
      ) ON CONFLICT (
          media_id, 
          user_id
      ) DO
      UPDATE SET 
        latest_alert_ts10 = $current_timestamp10; \
      "`
      echo "[文件下载成功通知 P2] 写入结果 (仅覆盖时间戳): $result"
      
    # 满足冷却时间, 向满足冷却时间的用户发送通知
    curl -s -X POST -H "authorization: Bearer $access_token" -d "{\"user_id\":\"$1\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"文件名: $target_media_filename_urldecoded\u000a该文件截至本次下载时在本服务器上的有效期剩余 $timestamp_diff10_to_hours 小时.\u000a\u000a如果文件名显示为 \u0022未知\u0022 的可能原因: \u000aa) 此文件上传到加密房间;\u000ab) 此文件使用 Element X 上传.\u000a\u000a下次此文件的有关通知需要等待至少 30 分钟.\"}}" "$synapse_url/_synapse/admin/v1/send_server_notice"
    fi
  
  else
    # 对不存在的媒体 ID 进行补充 (区分下载者用户 ID)
    result2=`docker exec $postgres_container_name psql -X -A -d $postgres_database_name -U $postgres_database_operator_name -p $postgres_database_port -t -c \
    "\
    INSERT INTO $postgres_database_table_name (
      media_id,
      user_id,
      latest_alert_ts10
    )
    VALUES (
      '$2',
      '$1',
      $current_timestamp10); \
    "`

    echo "[文件下载成功通知 P2] 写入结果 (新增条目): $result2"
    
    # 由于刚才补充了不存在的媒体 ID, 因此不适用冷却时间, 立即向满足冷却时间的用户发送通知
    curl -s -X POST -H "authorization: Bearer $access_token" -d "{\"user_id\":\"$1\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"文件名: $target_media_filename_urldecoded\u000a该文件截至本次下载时在本服务器上的有效期剩余 $timestamp_diff10_to_hours 小时.\u000a\u000a如果文件名显示为 \u0022未知\u0022 的可能原因: \u000aa) 此文件上传到加密房间;\u000ab) 此文件使用 Element X 上传.\u000a\u000a下次此文件的有关通知需要等待至少 30 分钟.\"}}" "$synapse_url/_synapse/admin/v1/send_server_notice"

  fi
else
  echo "[文件下载成功通知 P2] 目标媒体不满足指定大小, 跳过通知."
fi


# 已知 Element X for Android 无论是否上传文件到加密房间, 始终不在 Synapse 日志中显示文件名 (/_matrix/media/v3/upload 没有带上 filename 参数), 可能为缺陷.