# 目标容器名称
container_name=`cat ./constants.json | jq -r ".container_name"`

# Synapse 实例
synapse_url=`cat ./constants.json | jq -r ".synapse_url"`
access_token=`cat ./constants.json | jq -r ".synapse_access_token"`

# Postgres 数据库连接信息 (新)
postgres_container_name=`cat ./constants.json | jq -r ".database.container_name"` # 容器名称
postgres_database_port=`cat ./constants.json | jq -r ".database.postgres_database_port"` # 数据库端口
postgres_database_name=`cat ./constants.json | jq -r ".database.postgres_database_name2"` # 数据库名称
postgres_database_operator_name=`cat ./constants.json | jq -r ".database.postgres_database_operator_name"` # 操作数据库使用的用户名
postgres_database_table_name="media_download_alert_cooldown_new" # 目标数据库中的目标表名称

# 获取指定媒体 ID 在数据库中是否存在 (区分下载者用户 ID)
# 针对有时无法确定条目是否存在 (既不返回 t 也不返回 f) 的现象, 适当延长超时 (暂定为 10 秒)
is_exist=`timeout 10 docker exec $postgres_container_name psql -X -A -d $postgres_database_name -U $postgres_database_operator_name -p $postgres_database_port -t -c \
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

# 计算当前时间戳 (10 位), 作为该媒体的冷却起始时间
current_timestamp10=`date +%s`

echo "[文件下载失败通知] 当前时间戳 (10 位): $current_timestamp10"
echo "[文件下载失败通知] 该条目 ($2) 在数据库中是否存在: $is_exist"

if [ $is_exist = "t" ]; # t = 是, f = 否
then
  # 获取指定媒体 ID 在数据库中最后一次记录的时间戳 (并且区分下载者用户 ID)
  latest_alert_ts10=`timeout 10 docker exec $postgres_container_name psql -X -A -d $postgres_database_name -U $postgres_database_operator_name -p $postgres_database_port -t -c \
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

  echo "[文件下载失败通知] 基于该媒体 ID ($2) 与用户 ID ($1) 在数据库中的时间戳 (10 位): $latest_alert_ts10"

  # 冷却时间 5 分钟 (300 秒)
  cooldown_time=300
  
  # 判断以上时间戳距今是否小于指定的冷却时间
  # 此变量仅用于存储以上时间戳的差
  timestamp_diff10_2=`expr $current_timestamp10 - $latest_alert_ts10`
  
  # 如果时间戳的差小于规定的冷却时间 (单位: 秒, 10 位时间戳)
  if [ $timestamp_diff10_2 -lt $cooldown_time ];
  then
    echo "[文件下载失败通知] 冷却时间不足 5 分钟, 跳过记录时间戳."
  else
    echo "[文件下载失败通知] 冷却时间已超过 5 分钟, 恢复记录时间戳."
    # echo "[文件下载失败通知] 基于该媒体 ID ($2) 与用户 ID ($1) 在数据库中的时间戳 (10 位): $latest_alert_ts10"

    # 覆盖现有条目中的时间戳 (并且区分下载者用户 ID)
    # 为 SQL 暂定设置 10 秒超时, 在耗时尽量短的前提下成功写入
    result=`timeout 10 docker exec $postgres_container_name psql -X -A -d $postgres_database_name -U $postgres_database_operator_name -p $postgres_database_port -t -c \
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
    
    echo "[文件下载失败通知] 写入结果 (仅覆盖时间戳): $result"
    
    # 满足冷却时间, 向满足冷却时间的用户发送通知
    curl -s -X POST -H "authorization: Bearer $access_token" -d "{\"user_id\":\"$1\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"你于刚才尝试下载的文件或媒体不存在, 可能的原因:\u000aa) 此文件因超过规定的保留期限而被自动删除;\u000ab) 此文件因违反使用条款而被删除.\u000ac) 此文件用于调试目的而被删除.\u000a\u000a文件 ID: $2\u000a被删除的文件或媒体对应一条消息, 将持续显示在历史消息记录中, 直到该条消息被删除.\u000a\u000a下次此文件的有关通知需要等待至少 5 分钟.\"}}" "$synapse_url/_synapse/admin/v1/send_server_notice"
  fi
else
  # 新增条目, 对不存在的媒体 ID 进行补充 (并且区分下载者用户 ID, 即同一个媒体 ID 可能存在多个条目, 因为它们所属的用户 ID 不同)
  # 为 SQL 暂定设置 10 秒超时, 在耗时尽量短的前提下成功写入
  result2=`timeout 10 docker exec $postgres_container_name psql -X -A -d $postgres_database_name -U $postgres_database_operator_name -p $postgres_database_port -t -c \
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

  echo "[文件下载失败通知] 写入结果 (新增条目): $result2"
  
  # 由于刚才补充了不存在的媒体 ID, 因此不适用冷却时间, 立即发送通知
  curl -s -X POST -H "authorization: Bearer $access_token" -d "{\"user_id\":\"$1\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"你于刚才尝试下载的文件或媒体不存在, 可能的原因:\u000aa) 此文件因超过规定的保留期限而被自动删除;\u000ab) 此文件因违反使用条款而被删除.\u000ac) 此文件用于调试目的而被删除.\u000a\u000a文件 ID: $2\u000a被删除的文件或媒体对应一条消息, 将持续显示在历史消息记录中, 直到该条消息被删除.\u000a\u000a下次此文件的有关通知需要等待至少 5 分钟.\"}}" "$synapse_url/_synapse/admin/v1/send_server_notice"
fi

