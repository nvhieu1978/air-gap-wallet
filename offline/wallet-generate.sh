#!/bin/bash

# Kịch bản sinh khóa và khôi phục ví Cardano Ngoại tuyến (Cold Wallet)
# Thực hiện:
# - Tạo cụm từ khôi phục 24 từ ngẫu nhiên hoặc khôi phục từ cụm từ có sẵn.
# - Dùng cardano-address hoặc cardano-cli sinh khóa gốc (root key), khóa thanh toán (payment key), và khóa ủy quyền (stake key).
# - Dùng cardano-cli chuyển đổi khóa/sinh khóa sang định dạng skey/vkey tương thích.
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

# Hàm kiểm tra file khả thi chạy
is_executable() {
    [ -x "$1" ] && [ ! -d "$1" ]
}

# Định nghĩa đường dẫn cho cardano-cli
CARDANO_CLI="cardano-cli"
if command -v cardano-cli &>/dev/null; then
    CARDANO_CLI_PATH="$(command -v cardano-cli)"
elif is_executable "$PROJECT_ROOT/cardano-cli"; then
    CARDANO_CLI_PATH="$PROJECT_ROOT/cardano-cli"
elif is_executable "$SCRIPT_DIR/cardano-cli"; then
    CARDANO_CLI_PATH="$SCRIPT_DIR/cardano-cli"
else
    CARDANO_CLI_PATH=""
fi

# Định nghĩa đường dẫn cho cardano-address
CARDANO_ADDRESS="cardano-address"
if command -v cardano-address &>/dev/null; then
    CARDANO_ADDRESS_PATH="$(command -v cardano-address)"
elif is_executable "$PROJECT_ROOT/cardano-address"; then
    CARDANO_ADDRESS_PATH="$PROJECT_ROOT/cardano-address"
elif is_executable "$SCRIPT_DIR/cardano-address"; then
    CARDANO_ADDRESS_PATH="$SCRIPT_DIR/cardano-address"
else
    CARDANO_ADDRESS_PATH=""
fi

# Kiểm tra các công cụ bắt buộc
if [ -z "$CARDANO_CLI_PATH" ]; then
    echo "Lỗi: Chưa cài đặt 'cardano-cli' trong hệ thống hoặc tại thư mục gốc/thư mục offline."
    exit 1
fi

command -v openssl > /dev/null || { echo "Lỗi: Chưa cài đặt 'openssl'."; exit 1; }

# Xác định công cụ sinh khóa (KEY_GEN_TOOL)
KEY_GEN_TOOL="cardano-cli"
if [ -n "$CARDANO_ADDRESS_PATH" ]; then
    echo "--------------------------------------------------------"
    echo "Phát hiện hệ thống có cả 'cardano-address' và 'cardano-cli'."
    echo "Chọn công cụ bạn muốn sử dụng để sinh khóa:"
    echo "1) cardano-address (Mặc định)"
    echo "2) cardano-cli"
    read -p "Nhập lựa chọn của bạn (1/2, mặc định 1): " tool_choice
    if [ "$tool_choice" = "2" ]; then
        KEY_GEN_TOOL="cardano-cli"
    else
        KEY_GEN_TOOL="cardano-address"
    fi
else
    echo "Không tìm thấy 'cardano-address'. Hệ thống tự động chuyển sang sử dụng 'cardano-cli' để sinh khóa từ mnemonic."
    KEY_GEN_TOOL="cardano-cli"
fi

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

# Hàm hiển thị cụm từ 24 từ bảo mật theo dạng bảng 4 từ/hàng, 3 hàng/trang để tránh lộ thông tin
display_mnemonic_paged() {
    local raw_phrase="$1"
    local title="${2:-CỤM TỪ KHÔI PHỤC (MNEMONIC) BẢO MẬT}"

    # Chuyển chuỗi thành mảng các từ
    local words=()
    read -r -a words <<< "$raw_phrase"

    if [ ${#words[@]} -ne 24 ]; then
        echo "Lỗi: Cụm từ khôi phục không đúng 24 từ (hiện tại có ${#words[@]} từ)."
        return 1
    fi

    # Trang 1: Hàng 1 - 3 (Từ 1 - 12)
    clear 2>/dev/null || echo -e "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"
    echo "========================================================"
    echo "   $title - TRANG 1/2 (TỪ 1 - 12)"
    echo "========================================================"
    echo "  (Hệ thống chỉ hiển thị cùng lúc 3 hàng 4 từ để tránh bị lộ)"
    echo "--------------------------------------------------------"
    printf " %02d. %-12s %02d. %-12s %02d. %-12s %02d. %-12s\n" 1 "${words[0]}" 2 "${words[1]}" 3 "${words[2]}" 4 "${words[3]}"
    printf " %02d. %-12s %02d. %-12s %02d. %-12s %02d. %-12s\n" 5 "${words[4]}" 6 "${words[5]}" 7 "${words[6]}" 8 "${words[7]}"
    printf " %02d. %-12s %02d. %-12s %02d. %-12s %02d. %-12s\n" 9 "${words[8]}" 10 "${words[9]}" 11 "${words[10]}" 12 "${words[11]}"
    echo "--------------------------------------------------------"
    read -p "Nhấn ENTER để chuyển sang Trang 2 (Từ 13 - 24)..." dummy

    # Trang 2: Hàng 4 - 6 (Từ 13 - 24)
    clear 2>/dev/null || echo -e "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"
    echo "========================================================"
    echo "   $title - TRANG 2/2 (TỪ 13 - 24)"
    echo "========================================================"
    echo "  (Hệ thống chỉ hiển thị cùng lúc 3 hàng 4 từ để tránh bị lộ)"
    echo "--------------------------------------------------------"
    printf " %02d. %-12s %02d. %-12s %02d. %-12s %02d. %-12s\n" 13 "${words[12]}" 14 "${words[13]}" 15 "${words[14]}" 16 "${words[15]}"
    printf " %02d. %-12s %02d. %-12s %02d. %-12s %02d. %-12s\n" 17 "${words[16]}" 18 "${words[17]}" 19 "${words[18]}" 20 "${words[19]}"
    printf " %02d. %-12s %02d. %-12s %02d. %-12s %02d. %-12s\n" 21 "${words[20]}" 22 "${words[21]}" 23 "${words[22]}" 24 "${words[23]}"
    echo "--------------------------------------------------------"
    read -p "Nhấn ENTER để hoàn tất và ẩn toàn bộ cụm từ bảo mật..." dummy

    # Xóa màn hình và giải phóng biến chứa dữ liệu nhạy cảm khỏi bộ nhớ
    clear 2>/dev/null || echo -e "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"
    unset words raw_phrase dummy
    echo "Đã ẩn cụm từ khôi phục và dọn dẹp bộ nhớ an toàn."
    return 0
}

# Hàm xem cụm từ 24 từ của ví đã có (yêu cầu mật khẩu giải mã)
view_wallet_mnemonic() {
    local target_wallet=""
    if [ -n "$1" ]; then
        target_wallet="$1"
    else
        read -p "Nhập tên ví cần xem cụm từ khôi phục (ví dụ: C2VN): " target_wallet
        target_wallet=$(echo "$target_wallet" | tr -cd '[:alnum:]_-')
    fi

    if [ -z "$target_wallet" ]; then
        echo "Lỗi: Tên ví không được để trống."
        return 1
    fi

    local wallet_dir="./wallets/$target_wallet"
    local enc_file="$wallet_dir/phrase.prv.enc"

    if [ ! -f "$enc_file" ]; then
        echo "Lỗi: Không tìm thấy tệp '$enc_file'. Vui lòng kiểm tra lại tên ví."
        return 1
    fi

    read -s -p "Nhập mật khẩu bảo mật ví '$target_wallet' để giải mã: " password
    echo ""

    if [ -z "$password" ]; then
        echo "Lỗi: Mật khẩu không được để trống."
        return 1
    fi

    echo "Đang giải mã cụm từ khôi phục 24 từ..."
    local decrypted_phrase=""
    decrypted_phrase=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in "$enc_file" -pass pass:"$password" 2>/dev/null)

    if [ -z "$decrypted_phrase" ]; then
        echo "Lỗi: Giải mã thất bại. Mật khẩu không chính xác hoặc tệp tin bị hỏng."
        unset password
        return 1
    fi

    display_mnemonic_paged "$decrypted_phrase" "VÍ $target_wallet - CỤM TỪ KHÔI PHỤC"
    unset password decrypted_phrase
    return 0
}

GEN_MODE=""

# Giao diện chính sinh khóa
while true; do
    echo "--------------------------------------------------------"
    echo "Trình Tạo Khóa Ví Cardano Ngoại Tuyến (Offline)"
    echo "Vui lòng chọn một phương án:"
    echo "1. Tạo ví mới hoàn toàn"
    echo "2. Khôi phục ví cũ từ cụm 24 từ bảo mật"
    echo "3. Xem 24 từ khôi phục của ví (Giải mã bằng mật khẩu)"
    echo "4. Quay lại"
    read -p "Nhập lựa chọn của bạn (1/2/3/4): " choice

    case $choice in
        1)
            GEN_MODE="new"
            echo "Đang tạo cụm từ khôi phục 24 từ mới..."
            # Sinh cụm từ 24 từ lưu trữ trực tiếp vào RAM disk
            if [ "$KEY_GEN_TOOL" = "cardano-address" ]; then
                "$CARDANO_ADDRESS_PATH" recovery-phrase generate --size 24 > "$TMP_DIR/phrase.prv"
            else
                "$CARDANO_CLI_PATH" key generate-mnemonic --size 24 --out-file "$TMP_DIR/phrase.prv"
            fi
            echo "Cụm từ bảo mật tạm thời đã được tạo trong bộ nhớ RAM."
            break
            ;;
        2)
            GEN_MODE="restore"
            # Nhập cụm từ khôi phục của người dùng (ẩn ký tự để bảo mật) và lưu trực tiếp vào RAM
            read -s -p "Nhập cụm 24 từ khôi phục (cách nhau bởi khoảng trắng): " phrase
            echo ""
            # Chuẩn hóa khoảng trắng của mnemonic và lưu vào RAM
            echo "$phrase" | tr -s ' ' '\n' | tr -d '\r' | paste -sd ' ' - > "$TMP_DIR/phrase.prv"
            echo "Đã nạp cụm từ khôi phục vào bộ nhớ RAM."
            break
            ;;
        3)
            view_wallet_mnemonic "$WALLET_NAME"
            echo ""
            ;;
        4)
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

if [ "$KEY_GEN_TOOL" = "cardano-address" ]; then
    echo "Bắt đầu sinh khóa bằng cardano-address..."
    # Bước 1: Tạo khóa gốc (Root Private Key) từ cụm từ bảo mật lưu trên RAM
    "$CARDANO_ADDRESS_PATH" key from-recovery-phrase Shelley < "$TMP_DIR/phrase.prv" > "$TMP_DIR/root.prv"

    # Bước 2: Tạo khóa thanh toán (Payment Key) lưu trên RAM
    "$CARDANO_ADDRESS_PATH" key child 1852H/1815H/0H/0/0 < "$TMP_DIR/root.prv" > "$TMP_DIR/payment.prv"
    "$CARDANO_ADDRESS_PATH" key public --without-chain-code < "$TMP_DIR/payment.prv" > "$WALLET_DIR/payment.pub"

    # Chuyển đổi khóa thanh toán riêng tư sang định dạng skey của cardano-cli lưu trên RAM
    "$CARDANO_CLI_PATH" key convert-cardano-address-key --shelley-payment-key \
        --signing-key-file "$TMP_DIR/payment.prv" \
        --out-file "$TMP_DIR/payment.skey"

    # Xuất khóa công khai tương ứng (vkey) lưu vào thư mục ví (công khai)
    "$CARDANO_CLI_PATH" key verification-key \
        --signing-key-file "$TMP_DIR/payment.skey" \
        --verification-key-file "$WALLET_DIR/payment.vkey"

    # Bước 3: Tạo khóa ủy quyền (Stake Key) lưu trên RAM
    "$CARDANO_ADDRESS_PATH" key child 1852H/1815H/0H/2/0 < "$TMP_DIR/root.prv" > "$TMP_DIR/stake.prv"

    # Chuyển đổi khóa ủy quyền riêng tư sang định dạng skey của cardano-cli lưu trên RAM
    "$CARDANO_CLI_PATH" key convert-cardano-address-key \
        --signing-key-file "$TMP_DIR/stake.prv" \
        --shelley-stake-key \
        --out-file "$TMP_DIR/stake.skey"

    # Xuất khóa ủy quyền công khai mở rộng lưu trên RAM
    "$CARDANO_CLI_PATH" key verification-key \
        --signing-key-file "$TMP_DIR/stake.skey" \
        --verification-key-file "$TMP_DIR/Ext_ShelleyStake.vkey"

    # Chuyển đổi về dạng khóa ủy quyền công khai không mở rộng chuẩn lưu vào thư mục ví (công khai)
    "$CARDANO_CLI_PATH" key non-extended-key \
        --extended-verification-key-file "$TMP_DIR/Ext_ShelleyStake.vkey" \
        --verification-key-file "$WALLET_DIR/stake.vkey"
else
    echo "Bắt đầu sinh khóa bằng cardano-cli..."
    # Bước 1: Tạo khóa thanh toán (Payment Key) trực tiếp từ cụm từ bảo mật lưu trên RAM
    if ! "$CARDANO_CLI_PATH" key derive-from-mnemonic \
        --mnemonic-from-file "$TMP_DIR/phrase.prv" \
        --account-number 0 \
        --payment-key-with-number 0 \
        --signing-key-file "$TMP_DIR/payment.skey"; then
        echo "Lỗi: Không thể sinh khóa thanh toán từ mnemonic. Có thể cụm từ khôi phục không hợp lệ."
        exit 1
    fi

    # Xuất khóa công khai tương ứng (vkey) lưu vào thư mục ví (công khai)
    "$CARDANO_CLI_PATH" key verification-key \
        --signing-key-file "$TMP_DIR/payment.skey" \
        --verification-key-file "$WALLET_DIR/payment.vkey"

    # Bước 2: Tạo khóa ủy quyền (Stake Key) trực tiếp từ cụm từ bảo mật lưu trên RAM
    if ! "$CARDANO_CLI_PATH" key derive-from-mnemonic \
        --mnemonic-from-file "$TMP_DIR/phrase.prv" \
        --account-number 0 \
        --stake-key-with-number 0 \
        --signing-key-file "$TMP_DIR/stake.skey"; then
        echo "Lỗi: Không thể sinh khóa ủy quyền từ mnemonic."
        exit 1
    fi

    # Xuất khóa ủy quyền công khai mở rộng lưu trên RAM
    "$CARDANO_CLI_PATH" key verification-key \
        --signing-key-file "$TMP_DIR/stake.skey" \
        --verification-key-file "$TMP_DIR/Ext_ShelleyStake.vkey"

    # Chuyển đổi về dạng khóa ủy quyền công khai không mở rộng chuẩn lưu vào thư mục ví (công khai)
    "$CARDANO_CLI_PATH" key non-extended-key \
        --extended-verification-key-file "$TMP_DIR/Ext_ShelleyStake.vkey" \
        --verification-key-file "$WALLET_DIR/stake.vkey"
fi

# Bước 3: Tạo địa chỉ ví thanh toán lưu vào thư mục ví (công khai)
"$CARDANO_CLI_PATH" address build \
    --payment-verification-key-file "$WALLET_DIR/payment.vkey" \
    $NETWORK_PARAM \
    --stake-verification-key-file "$WALLET_DIR/stake.vkey" \
    --out-file "$WALLET_DIR/payment.addr"

# Tạo địa chỉ ví ủy quyền lưu vào thư mục ví (công khai)
"$CARDANO_CLI_PATH" conway stake-address build \
    --stake-verification-key-file "$WALLET_DIR/stake.vkey" \
    --out-file "$WALLET_DIR/stake.addr" \
    $NETWORK_PARAM

# Bước 4: Tiến hành mã hóa các file nhạy cảm từ RAM ra đĩa cứng ở dạng mã hóa (.enc)
echo "Đang mã hóa các tệp khóa riêng tư bảo mật bằng mật khẩu của bạn..."
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -out "$WALLET_DIR/payment.skey.enc" -in "$TMP_DIR/payment.skey" -pass pass:"$password"
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -out "$WALLET_DIR/stake.skey.enc" -in "$TMP_DIR/stake.skey" -pass pass:"$password"
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -out "$WALLET_DIR/phrase.prv.enc" -in "$TMP_DIR/phrase.prv" -pass pass:"$password"

NEW_PHRASE=""
if [ "$GEN_MODE" = "new" ] && [ -f "$TMP_DIR/phrase.prv" ]; then
    NEW_PHRASE=$(cat "$TMP_DIR/phrase.prv")
fi

# Dọn dẹp thư mục tạm chứa các khóa thô chưa mã hóa bằng shred
cleanup_gen

# Xuất thông tin hiển thị thành công
echo "--------------------------------------------------------"
echo "Quá trình tạo khóa ví đã hoàn tất thành công!"
echo "Công cụ sinh khóa đã sử dụng: $KEY_GEN_TOOL"
echo "Địa chỉ ví công khai của bạn: $(cat "$WALLET_DIR/payment.addr")"
echo "Các tệp tin được sinh ra trong thư mục ví '$WALLET_DIR/':"
echo "  - payment.addr       : Địa chỉ ví nhận tiền (Công khai)"
echo "  - stake.addr         : Địa chỉ ví ủy quyền stake (Công khai)"
echo "  - payment.vkey       : Khóa xác minh thanh toán (Công khai)"
echo "  - stake.vkey         : Khóa xác minh ủy quyền (Công khai)"
if [ "$KEY_GEN_TOOL" = "cardano-address" ]; then
echo "  - payment.pub        : Khóa công khai thô (Công khai)"
fi
echo "  - payment.skey.enc   : Khóa ký thanh toán ĐÃ MÃ HÓA (Riêng tư - Bảo mật cao)"
echo "  - stake.skey.enc     : Khóa ký ủy quyền ĐÃ MÃ HÓA (Riêng tư - Bảo mật cao)"
echo "  - phrase.prv.enc     : Cụm 24 từ khôi phục ĐÃ MÃ HÓA (Riêng tư - Bảo mật cao)"
echo "--------------------------------------------------------"

if [ "$GEN_MODE" = "new" ] && [ -n "$NEW_PHRASE" ]; then
    echo ""
    echo "LƯU Ý BẢO MẬT: Cụm 24 từ khôi phục của ví vừa được tạo thành công."
    read -p "Vui lòng chuẩn bị giấy/bút và nhấn ENTER để bắt đầu xem cụm từ khôi phục..." dummy_enter
    display_mnemonic_paged "$NEW_PHRASE" "VÍ $WALLET_NAME - CỤM TỪ KHÔI PHỤC MỚI TẠO"
    unset NEW_PHRASE dummy_enter
fi
