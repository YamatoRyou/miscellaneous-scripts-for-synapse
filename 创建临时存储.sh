# 进入当前脚本所在目录
cd "$(dirname "$0")"

# 临时目录
# tmp_path="/tmp/{251792DA-C8DB-77D8-0AA5-B58ED6B94C90}"
tmp_path=`cat ./tmp_storage_path.json | jq -r ".tmp_storage_path"`

# 尝试创建大小为 1 MB 的 Ramdisk, 用于存储临时文件
if [ ! -d "${tmp_path}" ]
then
  mkdir "${tmp_path}"
  mount -t tmpfs -o size=1M tmpfs $tmp_path
  echo "[文件上传超限通知与删除 P1] 已创建 Ramdisk (大小 1 MB), 目录 ${tmp_path}."
else
  echo "[文件上传超限通知与删除 P1] Ramdisk ${tmp_path} 已存在, 跳过创建."
fi