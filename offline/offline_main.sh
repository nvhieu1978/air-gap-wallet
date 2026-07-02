#!/bin/bash

# Kịch bản giao diện chính cho Ví Cardano Ngoại tuyến (Cold Wallet)
# Các tính năng:
# - Tạo mới / Khôi phục ví Cardano
# - Quét/Đọc giao dịch thô chưa ký (Webcam, File, hoặc Dán thủ công)
# - BẢO MẬT: Giải mã khóa riêng tư bằng mật khẩu và ghi tạm THẲNG VÀO RAM DISK (/dev/shm)
# - Thực hiện ký giao dịch ngoại tuyến một cách an toàn
# - Xuất giao dịch đã ký thành mã QR và chuỗi hex CBOR

# Tải cấu hình mạng lưới ngoại tuyến
if [ -f "./config.env" ]; then
    source ./config.env
else
    NETWORK_PARAM="--testnet-magic 2"
fi

# Thiết lập thư mục làm việc tạm thời trong RAM (sử dụng /dev/shm) hoặc thư mục hiện tại nếu không khả dụng
if [ -d "/dev/shm" ] && [ -w "/dev/shm" ]; then
    TMP_DIR="/dev/shm/cardano-airgap-sign-$$"
    mkdir -p "$TMP_DIR"
    chmod 700 "$TMP_DIR"
else
    TMP_DIR="./tmp-keys-$$"
    mkdir -p "$TMP_DIR"
fi
TMP_KEY_PATH="$TMP_DIR/payment.skey.tmp"

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

# Hàm dọn dẹp an toàn các tệp khóa thô tạm thời trên RAM/Disk khi chương trình tắt
cleanup() {
    if [ -d "$TMP_DIR" ]; then
        for file in "$TMP_DIR"/*; do
            if [ -f "$file" ]; then
                # Sử dụng lệnh shred để hủy tệp tin chứa khóa thô, ngăn phục hồi từ ổ cứng
                shred -u "$file" 2>/dev/null || rm -f "$file"
            fi
        done
        rm -rf "$TMP_DIR"
    fi
}
# Đăng ký hàm dọn dẹp khi chương trình kết thúc (nhấn Ctrl+C hoặc tắt script)
trap cleanup EXIT

# Hàm đọc giao dịch thô từ phía người dùng cung cấp
get_raw_tx() {
    local wallet_dir="${1:-.}"
    echo "--------------------------------------------------------"
    echo "Chọn phương thức nhập giao dịch thô:"
    echo "1. Quét mã QR bằng Webcam trực tiếp (cần cài đặt zbar-tools & webcam)"
    echo "2. Đọc mã QR từ tệp ảnh (cần cài đặt zbar-tools)"
    echo "3. Dán thủ công chuỗi hex CBOR giao dịch thô"
    echo "4. Đọc chuỗi hex giao dịch thô từ tệp văn bản (mặc định: tx_raw.txt)"
    read -p "Lựa chọn phương thức (1-4): " input_choice

    local qr_content=""
    case $input_choice in
        1)
            if ! command -v zbarcam &> /dev/null; then
                echo "Lỗi: 'zbarcam' (trong bộ zbar-tools) chưa được cài đặt."
                return 1
            fi
            echo "Đang mở webcam... Hãy đưa mã QR giao dịch thô từ máy online vào camera."
            qr_content=$(zbarcam --raw --oneshot 2>/dev/null)
            ;;
        2)
            if ! command -v zbarimg &> /dev/null; then
                echo "Lỗi: 'zbarimg' (trong bộ zbar-tools) chưa được cài đặt."
                return 1
            fi
            read -p "Nhập đường dẫn đến tệp ảnh chứa mã QR: " img_path
            if [ ! -f "$img_path" ]; then
                echo "Không tìm thấy tệp ảnh: $img_path"
                return 1
            fi
            qr_content=$(zbarimg --raw -q "$img_path" 2>/dev/null)
            ;;
        3)
            read -p "Nhập chuỗi hex CBOR thô (hoặc bắt đầu bằng TxBodyConway:): " qr_content
            ;;
        4)
            local txt_path=""
            read -p "Nhập đường dẫn tệp văn bản [tx_raw.txt hoặc $wallet_dir/tx_raw.txt]: " txt_path
            if [ -z "$txt_path" ]; then
                if [ -f "tx_raw.txt" ]; then
                    txt_path="tx_raw.txt"
                elif [ -f "$wallet_dir/tx_raw.txt" ]; then
                    txt_path="$wallet_dir/tx_raw.txt"
                else
                    txt_path="tx_raw.txt"
                fi
            fi
            if [ ! -f "$txt_path" ]; then
                echo "Lỗi: Không tìm thấy tệp: $txt_path"
                return 1
            fi
            qr_content=$(cat "$txt_path")
            ;;
        *)
            echo "Lựa chọn không hợp lệ."
            return 1
            ;;
    esac

    # Loại bỏ khoảng trắng và ký tự xuống dòng dư thừa
    qr_content=$(echo "$qr_content" | tr -d '\r\n[:space:]')
    
    # Xác định loại giao dịch thông qua tiền tố nhận dạng
    if [[ "$qr_content" == TxBodyConwayDelegation:* ]]; then
        IS_DELEGATION=true
        qr_content=${qr_content#TxBodyConwayDelegation:}
        echo "Nhận diện loại giao dịch: ỦY THÁC (Stake Pool & DRep)"
    else
        IS_DELEGATION=false
        qr_content=${qr_content#TxBodyConway:}
        echo "Nhận diện loại giao dịch: GIAO DỊCH THÔNG THƯỜNG"
    fi
    
    if [[ -z "$qr_content" ]]; then
        echo "Lỗi: Không nhận được dữ liệu giao dịch thô."
        return 1
    fi
    
    # Kiểm tra xem chuỗi có phải định dạng hex hợp lệ không
    if [[ ! "$qr_content" =~ ^[0-9a-fA-F]+$ ]]; then
        echo "Lỗi: Chuỗi CBOR không hợp lệ (không phải hệ thập lục phân)."
        return 1
    fi

    RAW_CBOR_HEX="$qr_content"
    return 0
}

# Hàm lấy loại envelope tương thích với phiên bản cardano-cli
get_envelope_type() {
    local cli_version=""
    if command -v "$CARDANO_CLI" &>/dev/null; then
        # Lấy số phiên bản chính đầu tiên (ví dụ: 8, 9, 10, 11)
        cli_version=$("$CARDANO_CLI" --version | head -n 1 | grep -oE 'cardano-cli [0-9]+' | grep -oE '[0-9]+')
    fi

    # Mặc định với cardano-cli v9, v10, v11 trở lên, loại envelope cho giao dịch thô và đã ký đều là "Tx ConwayEra"
    if [ -n "$cli_version" ] && [ "$cli_version" -lt 9 ]; then
        echo "TxBodyConway"
    else
        echo "Tx ConwayEra"
    fi
}

# Hàm thực hiện ký giao dịch ngoại tuyến
sign_transaction() {
    # Nhập tên ví thực hiện ký từ người dùng
    local wallet_name=""
    local IS_DELEGATION=false
    read -p "Nhập tên ví thực hiện ký (ví dụ: C2VN): " wallet_name
    wallet_name=$(echo "$wallet_name" | tr -cd '[:alnum:]_-')
    local wallet_dir="./wallets/$wallet_name"

    # Kiểm tra sự tồn tại của khóa mã hóa thanh toán riêng tư
    local skey_enc_path=""
    if [ -n "$wallet_name" ] && [ -f "$wallet_dir/payment.skey.enc" ]; then
        skey_enc_path="$wallet_dir/payment.skey.enc"
    elif [ -f "payment.skey.enc" ]; then
        skey_enc_path="payment.skey.enc"
        wallet_dir="."
    else
        echo "Lỗi: Không tìm thấy payment.skey.enc tại '$wallet_dir/payment.skey.enc'."
        echo "Vui lòng tạo ví trước khi ký hoặc kiểm tra lại tên ví."
        return 1
    fi

    # Gọi hàm lấy giao dịch thô từ nguồn QR/văn bản
    if ! get_raw_tx "$wallet_dir"; then
        echo "Tải giao dịch thô thất bại."
        return 1
    fi

    # Đảm bảo thư mục tạm thời trong RAM tồn tại
    mkdir -p "$TMP_DIR"
    chmod 700 "$TMP_DIR"

    local env_type
    env_type=$(get_envelope_type)

    # Tái tạo lại tệp tin JSON cấu trúc giao dịch thô cho cardano-cli nhận diện (Lưu tạm trên RAM)
    cat <<EOF > "$TMP_DIR/tx.raw"
{
    "type": "$env_type",
    "description": "",
    "cborHex": "$RAW_CBOR_HEX"
}
EOF
    echo "Đã tái cấu trúc tệp tin giao dịch thô tạm trên RAM (Loại: $env_type)."

    # Yêu cầu nhập mật khẩu bảo mật ví để giải mã khóa riêng tư tạm thời
    read -s -p "Nhập mật khẩu ví: " password
    echo ""

    echo "Đang giải mã khóa riêng tư thanh toán..."
    # Giải mã trực tiếp ra RAM Disk
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in "$skey_enc_path" -out "$TMP_KEY_PATH" -pass pass:"$password" 2>/dev/null
    
    # Kiểm tra xem việc giải mã có thành công không
    if [ ! -f "$TMP_KEY_PATH" ] || [ ! -s "$TMP_KEY_PATH" ]; then
        echo "Lỗi: Giải mã khóa riêng tư thất bại (Mật khẩu sai hoặc file bị lỗi)."
        cleanup
        return 1
    fi

    # Mảng chứa các tham số ký
    local sign_args=()
    sign_args+=("--signing-key-file" "$TMP_KEY_PATH")

    # Kiểm tra và giải mã thêm stake key nếu cần thiết (đối với giao dịch ủy thác)
    local stake_enc_path="$wallet_dir/stake.skey.enc"
    local TMP_STAKE_KEY_PATH="$TMP_DIR/stake.skey.tmp"
    if [ -f "$stake_enc_path" ]; then
        local need_stake_sign=false
        if [ "$IS_DELEGATION" = true ]; then
            echo "Phát hiện giao dịch ủy thác (Stake Pool/DRep). Tự động dùng thêm khóa Stake để ký."
            need_stake_sign=true
        else
            echo "Phát hiện khóa Stake (stake.skey.enc)."
            read -p "Giao dịch này có phải là giao dịch ủy thác (Stake/DRep) cần chữ ký khóa Stake không? (y/N): " choice_stake
            if [[ "$choice_stake" =~ ^[yY](e[sS])?$ ]]; then
                need_stake_sign=true
            fi
        fi

        if [ "$need_stake_sign" = true ]; then
            echo "Đang giải mã khóa riêng tư stake..."
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in "$stake_enc_path" -out "$TMP_STAKE_KEY_PATH" -pass pass:"$password" 2>/dev/null
            if [ -f "$TMP_STAKE_KEY_PATH" ] && [ -s "$TMP_STAKE_KEY_PATH" ]; then
                sign_args+=("--signing-key-file" "$TMP_STAKE_KEY_PATH")
                echo "Đã giải mã khóa riêng tư stake thành công."
            else
                echo "Lỗi: Giải mã khóa riêng tư stake thất bại hoặc mật khẩu không hợp lệ."
                cleanup
                return 1
            fi
        fi
    fi

    echo "Đang tiến hành ký giao dịch ngoại tuyến..."
    # Gọi cardano-cli ký giao dịch thô bằng các khóa riêng tư vừa giải mã tạm thời trên RAM
    if "$CARDANO_CLI" conway transaction sign \
        "${sign_args[@]}" \
        $NETWORK_PARAM \
        --tx-body-file "$TMP_DIR/tx.raw" \
        --out-file "$TMP_DIR/tx.signed"; then
        
        echo "Đã ký giao dịch thành công!"
        
        # Trích xuất chuỗi hex CBOR của giao dịch đã ký
        local signed_cbor_hex
        signed_cbor_hex=$(jq -r '.cborHex' "$TMP_DIR/tx.signed")
        
        # Ngay lập tức hủy và xóa sạch các khóa thô và file ký tạm thời trên RAM
        cleanup

        # Lưu chuỗi hex CBOR kèm tiền tố vào tệp tin tx_signed.txt
        echo "TxConway:$signed_cbor_hex" > "$wallet_dir/tx_signed.txt"
        echo "Đã lưu chuỗi giao dịch đã ký vào tệp: $wallet_dir/tx_signed.txt"

        # Xuất mã QR đã ký nếu hệ thống có cài đặt qrencode
        if command -v qrencode &> /dev/null; then
            echo "--------------------------------------------------------"
            echo "MÃ QR GIAO DỊCH ĐÃ KÝ (Dùng máy Online quét mã này để gửi):"
            qrencode -t ansiutf8 "TxConway:$signed_cbor_hex"
            qrencode -o "$wallet_dir/tx_signed_qr.png" "TxConway:$signed_cbor_hex"
            echo "Đã lưu ảnh QR đã ký tại: $wallet_dir/tx_signed_qr.png"
        else
            echo "Cảnh báo: Không tìm thấy 'qrencode'. Bỏ qua hiển thị QR trên terminal."
        fi

        echo "--------------------------------------------------------"
        echo "CHUỖI HEX CBOR GIAO DỊCH ĐÃ KÝ (Đã lưu vào $wallet_dir/tx_signed.txt hoặc copy chuỗi dưới):"
        echo "TxConway:$signed_cbor_hex"
        echo "--------------------------------------------------------"
    else
        echo "Lỗi: Không thể ký giao dịch."
        cleanup
        return 1
    fi
}

# Vòng lặp giao diện chính của máy Offline
while true; do
    echo "========================================================"
    echo "Menu Ví Cardano Ngoại Tuyến - Offline Wallet (Cold)"
    echo "========================================================"
    echo "1. Tạo mới / Khôi phục ví (Mã hóa bảo mật)"
    echo "2. Ký giao dịch ngoại tuyến"
    echo "3. Thoát"
    read -p "Nhập lựa chọn của bạn (1-3): " choice

    case $choice in
        1)
            bash ./wallet-generate.sh
            ;;
        2)
            sign_transaction
            ;;
        3)
            echo "Đang thoát chương trình..."
            exit 0
            ;;
        *)
            echo "Lựa chọn không hợp lệ."
            ;;
    esac
    echo ""
done
