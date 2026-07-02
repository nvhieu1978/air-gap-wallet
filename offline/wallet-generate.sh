#!/bin/bash

# Kịch bản sinh khóa và khôi phục ví Cardano Ngoại tuyến (Cold Wallet)
# Thực hiện:
# - Tạo cụm từ khôi phục 24 từ ngẫu nhiên hoặc khôi phục từ cụm từ có sẵn.
# - Dùng cardano-address sinh khóa gốc (root key), khóa thanh toán (payment key), và khóa ủy quyền (stake key).
# - Dùng cardano-cli chuyển đổi khóa sang định dạng skey/vkey tương thích.
# - Tạo địa chỉ thanh toán Cardano.
# - Mã hóa các tệp nhạy cảm (skey, mnemonics) bằng OpenSSL AES-256-CBC PBKDF2 (100k vòng).
# - BẢO MẬT: Tất cả khóa thô được xử lý trên RAM disk (/dev/shm) và được hủy vật lý bằng shred.

# Tải cấu hình mạng lưới
if [ -f "./config.env" ]; then
    source ./config.env
else
    NETWORK_PARAM="--testnet-magic 2"
fi

# Xác định thư mục dự án
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Định nghĩa đường dẫn cho cardano-cli
CARDANO_CLI="cardano-cli"
if ! command -v cardano-cli &>/dev/null; then
    if [ -f "$PROJECT_ROOT/cardano-cli" ] && [ -x "$PROJECT_ROOT/cardano-cli" ]; then
        CARDANO_CLI="$PROJECT_ROOT/cardano-cli"
    elif [ -f "$SCRIPT_DIR/cardano-cli" ] && [ -x "$SCRIPT_DIR/cardano-cli" ]; then
        CARDANO_CLI="$SCRIPT_DIR/cardano-cli"
    fi
fi

# Định nghĩa đường dẫn cho cardano-address
CARDANO_ADDRESS="cardano-address"
if ! command -v cardano-address &>/dev/null; then
    if [ -f "$PROJECT_ROOT/cardano-address" ] && [ -x "$PROJECT_ROOT/cardano-address" ]; then
        CARDANO_ADDRESS="$PROJECT_ROOT/cardano-address"
    elif [ -f "$SCRIPT_DIR/cardano-address" ] && [ -x "$SCRIPT_DIR/cardano-address" ]; then
        CARDANO_ADDRESS="$SCRIPT_DIR/cardano-address"
    fi
fi

# Kiểm tra các công cụ bắt buộc trên máy ngoại tuyến
command -v "$CARDANO_ADDRESS" > /dev/null || { echo "Lỗi: Chưa cài đặt 'cardano-address' trong hệ thống hoặc tại thư mục gốc."; exit 1; }
command -v "$CARDANO_CLI" > /dev/null || { echo "Lỗi: Chưa cài đặt 'cardano-cli' trong hệ thống hoặc tại thư mục gốc."; exit 1; }
command -v openssl > /dev/null || { echo "Lỗi: Chưa cài đặt 'openssl'."; exit 1; }

# Nhập tên ví từ người dùng
while true; do
    read -p "Nhập tên ví mới/cần khôi phục (ví dụ: C2VN): " WALLET_NAME
    # Loại bỏ các khoảng trắng và ký tự không hợp lệ cho tên thư mục
    WALLET_NAME=$(echo "$WALLET_NAME" | tr -cd '[:alnum:]_-')
    if [ -z "$WALLET_NAME" ]; then
        echo "Tên ví không hợp lệ. Vui lòng nhập tên ví chỉ chứa chữ cái, số, gạch ngang (-) hoặc gạch dưới (_)."
        continue
    fi
    break
done

WALLET_DIR="./wallets/$WALLET_NAME"
mkdir -p "$WALLET_DIR"

# Khởi tạo thư mục tạm thời trong RAM (sử dụng /dev/shm là tmpfs chạy hoàn toàn trên RAM)
# Nếu không có /dev/shm, sẽ dùng thư mục tạm thời trong thư mục hiện hành.
if [ -d "/dev/shm" ] && [ -w "/dev/shm" ]; then
    TMP_DIR="/dev/shm/cardano-airgap-gen-$$"
    mkdir -p "$TMP_DIR"
    chmod 700 "$TMP_DIR"
    echo "Phát hiện RAM Disk khả dụng. Tất cả khóa thô chưa mã hóa sẽ được xử lý trên RAM."
else
    TMP_DIR="./tmp-keys-$$"
    mkdir -p "$TMP_DIR"
    echo "Cảnh báo: Không thể ghi vào RAM Disk (/dev/shm). Sử dụng thư mục tạm trên đĩa cứng."
fi

# Đăng ký dọn dẹp thư mục tạm trên RAM/Disk khi kịch bản dừng đột ngột
cleanup_gen() {
    if [ -d "$TMP_DIR" ]; then
        echo "Đang dọn dẹp bộ nhớ RAM chứa khóa thô..."
        for file in "$TMP_DIR"/*; do
            if [ -f "$file" ]; then
                shred -u "$file" 2>/dev/null || rm -f "$file"
            fi
        done
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup_gen EXIT

# Giao diện chính sinh khóa
while true; do
    echo "--------------------------------------------------------"
    echo "Trình Tạo Khóa Ví Cardano Ngoại Tuyến (Offline)"
    echo "Vui lòng chọn một phương án:"
    echo "1. Tạo ví mới hoàn toàn"
    echo "2. Khôi phục ví cũ từ cụm 24 từ bảo mật"
    echo "3. Quay lại"
    read -p "Nhập lựa chọn của bạn (1/2/3): " choice

    case $choice in
        1)
            echo "Đang tạo cụm từ khôi phục 24 từ mới..."
            # Sinh cụm từ 24 từ lưu trữ trực tiếp vào RAM disk
            "$CARDANO_ADDRESS" recovery-phrase generate --size 24 > "$TMP_DIR/phrase.prv"
            echo "Cụm từ bảo mật tạm thời đã được tạo trong bộ nhớ RAM."
            break
            ;;
        2)
            # Nhập cụm từ khôi phục của người dùng (ẩn ký tự để bảo mật) và lưu trực tiếp vào RAM
            read -s -p "Nhập cụm 24 từ khôi phục (cách nhau bởi khoảng trắng): " phrase
            echo ""
            echo "$phrase" > "$TMP_DIR/phrase.prv"
            echo "Đã nạp cụm từ khôi phục vào bộ nhớ RAM."
            break
            ;;
        3)
            echo "Thoát trình tạo khóa..."
            exit 0
            ;;
        *)
            echo "Lựa chọn không hợp lệ. Vui lòng nhập lại."
            continue
            ;;
    esac
done

# Thiết lập mật khẩu mã hóa bảo vệ khóa riêng tư
while true; do
    read -s -p "Đặt mật khẩu bảo mật để mã hóa các khóa riêng tư: " password
    echo ""
    read -s -p "Xác nhận lại mật khẩu: " password_confirm
    echo ""
    if [ "$password" != "$password_confirm" ]; then
        echo "Mật khẩu xác nhận không trùng khớp. Vui lòng nhập lại."
        continue
    fi
    if [ -z "$password" ]; then
        echo "Mật khẩu không được để trống."
        continue
    fi
    break
done

# Bước 1: Tạo khóa gốc (Root Private Key) từ cụm từ bảo mật lưu trên RAM
"$CARDANO_ADDRESS" key from-recovery-phrase Shelley < "$TMP_DIR/phrase.prv" > "$TMP_DIR/root.prv"

# Bước 2: Tạo khóa thanh toán (Payment Key) lưu trên RAM
"$CARDANO_ADDRESS" key child 1852H/1815H/0H/0/0 < "$TMP_DIR/root.prv" > "$TMP_DIR/payment.prv"
"$CARDANO_ADDRESS" key public --without-chain-code < "$TMP_DIR/payment.prv" > "$WALLET_DIR/payment.pub"

# Chuyển đổi khóa thanh toán riêng tư sang định dạng skey của cardano-cli lưu trên RAM
"$CARDANO_CLI" key convert-cardano-address-key --shelley-payment-key \
    --signing-key-file "$TMP_DIR/payment.prv" \
    --out-file "$TMP_DIR/payment.skey"

# Xuất khóa công khai tương ứng (vkey) lưu vào thư mục ví (công khai)
"$CARDANO_CLI" key verification-key \
    --signing-key-file "$TMP_DIR/payment.skey" \
    --verification-key-file "$WALLET_DIR/payment.vkey"

# Bước 3: Tạo khóa ủy quyền (Stake Key) lưu trên RAM
"$CARDANO_ADDRESS" key child 1852H/1815H/0H/2/0 < "$TMP_DIR/root.prv" > "$TMP_DIR/stake.prv"

# Chuyển đổi khóa ủy quyền riêng tư sang định dạng skey của cardano-cli lưu trên RAM
"$CARDANO_CLI" key convert-cardano-address-key \
    --signing-key-file "$TMP_DIR/stake.prv" \
    --shelley-stake-key \
    --out-file "$TMP_DIR/stake.skey"

# Xuất khóa ủy quyền công khai mở rộng lưu trên RAM
"$CARDANO_CLI" key verification-key \
    --signing-key-file "$TMP_DIR/stake.skey" \
    --verification-key-file "$TMP_DIR/Ext_ShelleyStake.vkey"

# Chuyển đổi về dạng khóa ủy quyền công khai không mở rộng chuẩn lưu vào thư mục ví (công khai)
"$CARDANO_CLI" key non-extended-key \
    --extended-verification-key-file "$TMP_DIR/Ext_ShelleyStake.vkey" \
    --verification-key-file "$WALLET_DIR/stake.vkey"

# Bước 4: Tạo địa chỉ ví thanh toán lưu vào thư mục ví (công khai)
"$CARDANO_CLI" address build \
    --payment-verification-key-file "$WALLET_DIR/payment.vkey" \
    $NETWORK_PARAM \
    --stake-verification-key-file "$WALLET_DIR/stake.vkey" \
    --out-file "$WALLET_DIR/payment.addr"

# Tạo địa chỉ ví ủy quyền lưu vào thư mục ví (công khai)
"$CARDANO_CLI" conway stake-address build \
    --stake-verification-key-file "$WALLET_DIR/stake.vkey" \
    --out-file "$WALLET_DIR/stake.addr" \
    $NETWORK_PARAM

# Bước 5: Tiến hành mã hóa các file nhạy cảm từ RAM ra đĩa cứng ở dạng mã hóa (.enc)
echo "Đang mã hóa các tệp khóa riêng tư bảo mật bằng mật khẩu của bạn..."
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -out "$WALLET_DIR/payment.skey.enc" -in "$TMP_DIR/payment.skey" -pass pass:"$password"
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -out "$WALLET_DIR/stake.skey.enc" -in "$TMP_DIR/stake.skey" -pass pass:"$password"
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -out "$WALLET_DIR/phrase.prv.enc" -in "$TMP_DIR/phrase.prv" -pass pass:"$password"

# Dọn dẹp thư mục tạm chứa các khóa thô chưa mã hóa bằng shred
cleanup_gen

# Xuất thông tin hiển thị thành công
echo "--------------------------------------------------------"
echo "Quá trình tạo khóa ví đã hoàn tất thành công!"
echo "Địa chỉ ví công khai của bạn: $(cat "$WALLET_DIR/payment.addr")"
echo "Các tệp tin được sinh ra trong thư mục ví '$WALLET_DIR/':"
echo "  - payment.addr       : Địa chỉ ví nhận tiền (Công khai)"
echo "  - stake.addr         : Địa chỉ ví ủy quyền stake (Công khai)"
echo "  - payment.vkey       : Khóa xác minh thanh toán (Công khai)"
echo "  - stake.vkey         : Khóa xác minh ủy quyền (Công khai)"
echo "  - payment.pub        : Khóa công khai thô (Công khai)"
echo "  - payment.skey.enc   : Khóa ký thanh toán ĐÃ MÃ HÓA (Riêng tư - Bảo mật cao)"
echo "  - stake.skey.enc     : Khóa ký ủy quyền ĐÃ MÃ HÓA (Riêng tư - Bảo mật cao)"
echo "  - phrase.prv.enc     : Cụm 24 từ khôi phục ĐÃ MÃ HÓA (Riêng tư - Bảo mật cao)"
echo "--------------------------------------------------------"
