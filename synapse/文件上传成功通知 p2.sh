# Synapse 实例
synapse_url=`cat ./constants.json | jq -r ".synapse_url"`
access_token=`cat ./constants.json | jq -r ".synapse_access_token"`
synapse_server_name=`cat ./constants.json | jq -r ".synapse_server_name"`

# 文件大小门槛
filesize_limit=`cat ./constants.json | jq -r ".filesize_limit"` # 文件大小第一上限 5 MB (5242880 字节)
filesize_limit2=`cat ./constants.json | jq -r ".filesize_limit2"` # 文件大小第二上限 25 MB (26214400 字节)

# 自动调整数据大小单位函数 (新, 支持处理负数), 通过此函数将该指定的数值 (通常为字节数) 转换为合适的带单位的值, 保留 2 位小数
data_bytes_to_humanization_size_format () {
  local value=$1

  # 负数处理
  local negative_num=false
  if [ $value -lt 0 ]
  then
    negative_num=true
    value=$(( -value ))
  fi

  if [ $value -ge 1073741824 ]; # 如果大于等于 1073741824 字节 (1 GB)
  then
      datasize=$(awk "BEGIN {printf \"%.2f\", $value / 1024 / 1024 / 1024}") # 除法浮点运算
      datasize_with_unit="$datasize GB"
  elif [ $value -lt 1073741824 -a $value -ge 1048576 ]; # 如果小于 1073741824 字节 (1 GB) 且大于等于 1048576 字节 (1 MB)
  then
      datasize=$(awk "BEGIN {printf \"%.2f\", $value / 1024 / 1024}") # 除法浮点运算
      datasize_with_unit="$datasize MB"
  elif [ $value -lt 1048576 -a $value -ge 1024 ]; # 如果小于 1048576 字节 (1 MB) 且大于等于 1024 字节 (1 KB)
  then
      datasize=$(awk "BEGIN {printf \"%.2f\", $value / 1024}") # 除法浮点运算
      datasize_with_unit="$datasize KB"
  elif [ $value -lt 1024 ]; # 如果小于 1024 字节 (1 KB);
  then
      datasize_with_unit="$value B"
  fi
  
  # 再次判断 flag, 用于补回负号
  if [ $negative_num = true ]
  then
    local negative_sign="-"
  fi
  
  echo "$negative_sign$datasize_with_unit"
}

echo "[文件上传成功通知 P2] 复核 MXC ID: $1"

# 通过 MXC ID 查询媒体信息
media_info_json=`curl -X GET \
  -H "authorization: Bearer $access_token" \
  "$synapse_url/_synapse/admin/v1/media/$synapse_server_name/$1" | jq .`

# 获取文件大小 (字节)
upload_filesize=`echo $media_info_json | jq -r ".media_info.media_length"`

# 获取文件上传者用户 ID
uploader_userid=`echo $media_info_json | jq -r ".media_info.user_id"`

# 根据文件大小决定是否继续执行下面的代码 (大于 5 MB)
if [ $upload_filesize -gt $filesize_limit ];
then
  # 转换为带单位的友好格式
  upload_filesize_with_unit=`data_bytes_to_humanization_size_format $upload_filesize`

  # 获取文件上传时间戳 (13 位)
  upload_filetimestamp13=`echo $media_info_json | jq -r ".media_info.created_ts"`
  upload_filetimestamp10=(${upload_filetimestamp13:0:10}) # 转换为 10 位时间戳

  # 进一步文件创建日期 (人类友好格式)
  upload_filedate=`date -d @$(echo $upload_filetimestamp10 | cut -b1-10) "+%Y / %m / %d %H:%M:%S"`

  # 获取文件名
  upload_filename_preload=`echo $media_info_json | jq -r ".media_info.upload_name"` # 预检
  if [ "$upload_filename_preload" == "null" ] # 如果上传的媒体不含文件名 (在加密房间或使用 Element X 上传的媒体)
  then
    upload_filename_urldecoded="未知"
  else
    urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }
    upload_filename_urldecoded=`urldecode $upload_filename_preload`
    upload_filename_urldecoded=`urldecode $upload_filename_urldecoded` # 需要二次解码, 原因不明
  fi

  # 根据文件大小确定其距今有效期限
  if [ $upload_filesize -gt $filesize_limit -a $upload_filesize -le $filesize_limit2 ]; # 如果文件大小大于 5 MB (5242880 字节) 且小于等于 25 MB (26214400 字节), 按距今 365 天 (8760 小时) 计算
  then
    # 计算出文件到期时间戳 (10 位)
    upload_file_expire_timestamp10=`expr $upload_filetimestamp10 + 31536000`
    
    # 计算出文件过期时间 (人类友好格式)
    file_exprire_date=`date -d @$(echo $upload_file_expire_timestamp10) "+%Y / %m / %d %H:%M:%S"`

    # 文件过期提示词
    promt_keyword="365 天 (8760 小时)"

  elif [ $upload_filesize -gt $filesize_limit2 ]; # 如果文件大小大于 25 MB (26214401 字节), 按距今 7 天 (168 小时) 计算
  then
    # 计算出文件到期时间戳 (10 位)
    upload_file_expire_timestamp10=`expr $upload_filetimestamp10 + 604800`
    
    # 计算出文件过期时间 (人类友好格式)
    file_exprire_date=`date -d @$(echo $upload_file_expire_timestamp10) "+%Y / %m / %d %H:%M:%S"`
    
    # 文件过期提示词
    promt_keyword="7 天 (168 小时)"
  fi

  # 发送消息
  echo "[文件上传成功通知 P2] 用户 $uploader_userid 上传的媒体满足或大于指定大小, 发送通知."

  curl -s -X POST -H "authorization: Bearer $access_token" -d "{\"user_id\":\"$uploader_userid\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"文件名: $upload_filename_urldecoded\u000a文件大小: $upload_filesize_with_unit ($upload_filesize 字节)\u000a文件到期时间: $file_exprire_date\u000a文件上传时间: $upload_filedate\u000a\u000a按本服务器的规定, 该文件将于上传成功后保留 $promt_keyword, 到期后自动删除. 该文件最晚于到期后的 5 分钟内被删除.\u000a\u000a若符合以下情况, 则文件名不会显示:\u000aa) 该文件上传到加密房间;\u000ab) 使用 Element X 上传该文件;\u000ac) 部分平台在发送语音消息时不含文件名.\"}}" "$synapse_url/_synapse/admin/v1/send_server_notice"
else
    echo "[文件上传成功通知 P2] 用户 $uploader_userid 上传的媒体不满足指定大小, 不发送通知."
fi
