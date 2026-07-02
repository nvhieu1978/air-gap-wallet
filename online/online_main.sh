#!/bin/bash

# Kịch bản giao diện chính cho Ví Cardano Trực tuyến (Hot Wallet)
# Các tính năng:
# - Truy vấn số dư & UTXO thông qua API Blockfrost
# - Tạo giao dịch thô chưa ký (Raw Transaction) hỗ trợ định dạng ngoại tuyến
# - Tạo mã QR code và chuỗi văn bản cho giao dịch thô
# - Đọc mã QR giao dịch đã ký (Webcam, Ảnh hoặc Dán tay)
# - Submit giao dịch lên mạng lưới thông qua Blockfrost

# Tải cấu hình môi trường
if [ -f "./config.env" ]; then
    source ./config.env
else
    NETWORK_PARAM="--testnet-magic 2"
    BLOCKFROST_URL="https://cardano-preprod.blockfrost.io/api/v0"
    BLOCKFROST_API_KEY=""
fi

# Tải bộ helper liên kết Blockfrost
if [ -f "./blockfrost_helper.sh" ]; then
    source ./blockfrost_helper.sh
else
    echo "Lỗi: Không tìm thấy file blockfrost_helper.sh."
    exit 1
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

# Kiểm tra xem cardano-cli đã được cài đặt chưa (cần để build transaction)
command -v "$CARDANO_CLI" > /dev/null || { echo "Cảnh báo: '$CARDANO_CLI' chưa được cài đặt trong hệ thống hoặc tại thư mục gốc. Bạn không thể tạo giao dịch thô trực tiếp trên máy này."; }
command -v jq > /dev/null || { echo "Lỗi: 'jq' chưa được cài đặt. Vui lòng cài đặt trước."; exit 1; }
command -v curl > /dev/null || { echo "Lỗi: 'curl' chưa được cài đặt. Vui lòng cài đặt trước."; exit 1; }

# Hàm kiểm tra sự tồn tại của cardano-cli trước khi thực hiện các tác vụ liên quan
check_cli() {
    if ! command -v "$CARDANO_CLI" &> /dev/null; then
        echo "Lỗi: Yêu cầu công cụ '$CARDANO_CLI' để thực hiện thao tác này."
        return 1
    fi
    return 0
}

# Hàm lấy loại envelope giao dịch đã ký tương thích với phiên bản cardano-cli
get_envelope_type_signed() {
    local cli_version=""
    if command -v "$CARDANO_CLI" &>/dev/null; then
        cli_version=$("$CARDANO_CLI" --version | head -n 1 | grep -oE 'cardano-cli [0-9]+' | grep -oE '[0-9]+')
    fi

    if [ -n "$cli_version" ] && [ "$cli_version" -lt 9 ]; then
        echo "Tx Conway"
    else
        echo "Tx ConwayEra"
    fi
}

# Hàm phụ trợ để lấy địa chỉ người gửi (tự động nhận diện từ ví offline hoặc nhập tay)
get_sender_address() {
    local prompt_msg="$1"
    local address=""
    local wallet_name=""
    local use_offline=""
    
    read -p "Nhập tên ví Cardano từ máy offline (để trống nếu nhập địa chỉ thủ công): " wallet_name
    wallet_name=$(echo "$wallet_name" | tr -cd '[:alnum:]_-')
    
    # Thiết lập biến toàn cục cho tên ví đã chọn
    SELECTED_WALLET_NAME="$wallet_name"
    
    if [ -n "$wallet_name" ]; then
        if [ -f "../offline/wallets/$wallet_name/payment.addr" ]; then
            address=$(cat "../offline/wallets/$wallet_name/payment.addr")
            echo "Sử dụng địa chỉ ví '$wallet_name': $address" >&2
        elif [ -f "../offline/$wallet_name/payment.addr" ]; then
            address=$(cat "../offline/$wallet_name/payment.addr")
            echo "Sử dụng địa chỉ ví '$wallet_name': $address" >&2
        else
            echo "Không tìm thấy ví '$wallet_name' trong thư mục offline." >&2
            read -p "$prompt_msg: " address
        fi
    else
        if [ -f "../offline/payment.addr" ]; then
            local def_addr
            def_addr=$(cat ../offline/payment.addr)
            read -p "Phát hiện địa chỉ mặc định ($def_addr). Sử dụng địa chỉ này? [Y/n]: " use_offline
            if [[ "$use_offline" =~ ^[nN][oO]?$ ]]; then
                read -p "$prompt_msg: " address
            else
                address="$def_addr"
            fi
        else
            read -p "$prompt_msg: " address
        fi
    fi
    echo "$address"
}

# 1. Truy vấn UTXO và tính toán số dư của địa chỉ ví
check_balance() {
    local address=""
    address=$(get_sender_address "Nhập địa chỉ ví Cardano")
    
    if [ -z "$address" ]; then
        echo "Lỗi: Địa chỉ ví không được bỏ trống."
        return 1
    fi

    echo "Đang truy vấn các UTXO từ Blockfrost..."
    local utxos_json
    utxos_json=$(bf_get_utxos "$address")
    if [ $? -ne 0 ]; then
        echo "Lấy danh sách UTXO thất bại."
        return 1
    fi

    # Trích xuất và định dạng lại UTXO thành: hash#index : số_lovelace
    local sorted_utxos
    sorted_utxos=$(echo "$utxos_json" | jq -r '.[] | "\(.tx_hash)#\(.tx_index) : \(.amount[] | select(.unit=="lovelace") | .quantity)"')

    # Nếu không có UTXO nào
    if [ -z "$sorted_utxos" ]; then
        echo "--------------------------------------------------------"
        echo "Địa chỉ: $address"
        echo "Số dư: 0 ADA (Không tìm thấy UTXO nào)"
        echo "--------------------------------------------------------"
        return 0
    fi

    # Tính tổng số dư bằng Lovelace bằng cách cộng dồn các UTXO tìm được
    local total_lovelace=0
    while IFS= read -r line; do
        local lovelace
        lovelace=$(echo "$line" | awk -F' : ' '{print $2}')
        total_lovelace=$((total_lovelace + lovelace))
    done <<< "$sorted_utxos"

    # Đổi đơn vị Lovelace sang ADA (chia cho 1.000.000) thông qua Python để tránh sai số thập phân
    local total_ada
    total_ada=$(python3 -c "print(f'{${total_lovelace} / 1000000:.6f}')")

    echo "--------------------------------------------------------"
    echo "Địa chỉ: $address"
    echo "Tổng số dư: $total_ada ADA ($total_lovelace Lovelace)"
    echo "--------------------------------------------------------"
    echo "Danh sách UTXO chi tiết:"
    echo "$sorted_utxos" | nl -w2 -s'. '
    echo "--------------------------------------------------------"
}

# 2. Xây dựng giao dịch thô chưa ký (Raw Transaction)
build_tx() {
    check_cli || return 1

    local sender_address=""
    sender_address=$(get_sender_address "Nhập địa chỉ người gửi")

    if [ -z "$sender_address" ]; then
        echo "Lỗi: Địa chỉ người gửi không được để trống."
        return 1
    fi

    # Lấy thông tin UTXO để chọn input tiêu dùng
    echo "Đang truy vấn UTXO người gửi từ Blockfrost..."
    local utxos_json
    utxos_json=$(bf_get_utxos "$sender_address")
    if [ $? -ne 0 ] || [ -z "$utxos_json" ]; then
        echo "Truy cập UTXO lỗi hoặc ví không có tiền. Vui lòng kiểm tra lại."
        return 1
    fi

    # Định dạng lại danh sách UTXO
    local sorted_utxos
    sorted_utxos=$(echo "$utxos_json" | jq -r '.[] | "\(.tx_hash)#\(.tx_index) : \(.amount[] | select(.unit=="lovelace") | .quantity)"')

    if [ -z "$sorted_utxos" ]; then
        echo "Không tìm thấy UTXO nào cho địa chỉ này. Không thể tạo giao dịch."
        return 1
    fi

    echo "--------------------------------------------------------"
    echo "Danh sách UTXO khả dụng:"
    echo "$sorted_utxos" | nl -w2 -s'. '
    read -p "Nhập số thứ tự UTXO muốn dùng làm Input (ví dụ: '1', '1 3 4', hoặc 'all' để chọn tất cả): " utxo_input

    # Chuẩn hóa đầu vào (thay dấu phẩy bằng dấu cách và thu gọn khoảng trắng)
    utxo_input=$(echo "$utxo_input" | tr ',' ' ' | xargs)

    local total_utxos
    total_utxos=$(echo "$sorted_utxos" | wc -l)

    if [ "$utxo_input" = "all" ] || [ "$utxo_input" = "a" ]; then
        utxo_input=$(seq 1 "$total_utxos")
    fi

    if [ -z "$utxo_input" ]; then
        echo "Lựa chọn UTXO không hợp lệ."
        return 1
    fi

    # Mảng lưu danh sách các tham số --tx-in cho cardano-cli
    local tx_in_args=()
    local input_lovelace=0
    local utxo_num
    local has_invalid=false
    local selected_info=""

    for utxo_num in $utxo_input; do
        if ! [[ "$utxo_num" =~ ^[0-9]+$ ]] || [ "$utxo_num" -lt 1 ] || [ "$utxo_num" -gt "$total_utxos" ]; then
            echo "Lựa chọn UTXO thứ tự '$utxo_num' không hợp lệ."
            has_invalid=true
            break
        fi

        local selected_utxo_line
        selected_utxo_line=$(echo "$sorted_utxos" | sed -n "${utxo_num}p")
        
        local utxo_in
        utxo_in=$(echo "$selected_utxo_line" | awk -F' : ' '{print $1}')
        local utxo_lovelace
        utxo_lovelace=$(echo "$selected_utxo_line" | awk -F' : ' '{print $2}')

        tx_in_args+=("--tx-in" "$utxo_in")
        input_lovelace=$((input_lovelace + utxo_lovelace))
        selected_info="$selected_info\n  + $utxo_in ($((utxo_lovelace / 1000000)) ADA)"
    done

    if [ "$has_invalid" = true ] || [ ${#tx_in_args[@]} -eq 0 ]; then
        echo "Lỗi: Không có UTXO hợp lệ nào được chọn."
        return 1
    fi

    echo -e "Đã chọn ${#tx_in_args[@]} UTXO làm đầu vào (Tổng cộng $((input_lovelace / 1000000)) ADA):$selected_info"

    read -p "Nhập địa chỉ nhận tiền (Destination Address): " tx_out
    if [ -z "$tx_out" ]; then
        echo "Lỗi: Địa chỉ nhận không được bỏ trống."
        return 1
    fi

    read -p "Nhập số ADA muốn gửi đi: " tx_amount_ada
    local tx_amount_lovelace
    # Sử dụng Python để chuyển đổi chính xác từ ADA (thập phân) sang Lovelace (nguyên)
    tx_amount_lovelace=$(python3 -c "print(int(float('$tx_amount_ada') * 1000000))" 2>/dev/null)

    if [ -z "$tx_amount_lovelace" ] || [ $tx_amount_lovelace -le 0 ]; then
        echo "Lỗi: Số lượng ADA không hợp lệ."
        return 1
    fi

    if [ $tx_amount_lovelace -gt $input_lovelace ]; then
        echo "Lỗi: Số lượng tiền chuyển đi ($tx_amount_ada ADA) vượt quá số dư trong UTXO đầu vào."
        return 1
    fi

    # Lấy thông số kỷ nguyên (Epoch parameters) để tính toán phí giao dịch tối thiểu
    echo "Đang tải tham số mạng lưới (Protocol Parameters) từ Blockfrost..."
    bf_get_pparams "pparams.json"
    if [ $? -ne 0 ] || [ ! -f "pparams.json" ]; then
        echo "Tải tham số mạng lưới thất bại."
        return 1
    fi

    # Lấy slot mới nhất để cấu hình TTL (thời gian sống của giao dịch) tránh giao dịch bị treo vĩnh viễn
    echo "Đang lấy số slot hiện tại từ Blockfrost..."
    local latest_slot
    latest_slot=$(bf_get_latest_slot)
    if [ $? -ne 0 ]; then
        echo "Lấy thông tin slot block thất bại."
        rm -f pparams.json
        return 1
    fi
    # Đặt TTL hết hạn sau 1000 slot nữa (~1000 giây)
    local ttl=$((latest_slot + 1000))
    echo "Slot block mới nhất: $latest_slot. Đặt TTL giao dịch là $ttl."

    # Xây dựng giao dịch nháp (draft transaction) với cấu trúc tương đương giao dịch thật
    # (bao gồm cả đầu ra tiền thừa và TTL) để ước tính kích thước và phí chính xác nhất
    echo "Đang tính toán phí giao dịch tối thiểu (Minimum Fee)..."
    "$CARDANO_CLI" conway transaction build-raw \
        "${tx_in_args[@]}" \
        --tx-out "$tx_out+0" \
        --tx-out "$sender_address+0" \
        --invalid-hereafter "$ttl" \
        --fee 0 \
        --protocol-params-file pparams.json \
        --out-file tx.draft

    # Tính phí tối thiểu dựa trên kích thước giao dịch thô nháp vừa sinh
    local fee_raw
    fee_raw=$("$CARDANO_CLI" conway transaction calculate-min-fee \
        --tx-body-file tx.draft \
        --witness-count 1 \
        --protocol-params-file pparams.json \
        $NETWORK_PARAM)

    # Hỗ trợ cả định dạng JSON (v9+) và chuỗi text thô (v8-)
    local fee=""
    if echo "$fee_raw" | grep -q "fee"; then
        fee=$(echo "$fee_raw" | jq -r '.fee // .["fee"]' 2>/dev/null)
    fi
    # Nếu không phải JSON hoặc trích xuất thất bại, dùng grep lấy số đầu tiên
    if [ -z "$fee" ] || ! [[ "$fee" =~ ^[0-9]+$ ]]; then
        fee=$(echo "$fee_raw" | grep -oE '[0-9]+' | head -n 1)
    fi

    if [ -z "$fee" ] || [ $fee -le 0 ]; then
        echo "Lỗi: Tính toán phí giao dịch tối thiểu thất bại."
        rm -f tx.draft pparams.json
        return 1
    fi

    # Bổ sung khoảng đệm an toàn (safety buffer) là 15,000 Lovelace để tránh sai số CBOR
    fee=$((fee + 2000))
    echo "Phí tối thiểu ước tính (đã kèm buffer bảo mật): $fee Lovelace"

    # Tính lượng tiền thừa trả về (Change) = Đầu vào - Tiền gửi - Phí giao dịch
    local change=$((input_lovelace - tx_amount_lovelace - fee))
    
    # Kiểm tra số dư đầu vào có đủ thanh toán tổng chi phí không
    if [ $change -lt 0 ]; then
        echo "Lỗi: Không đủ tiền để trang trải lượng chuyển khoản ($tx_amount_lovelace Lovelace) và phí ($fee Lovelace)."
        rm -f tx.draft pparams.json
        return 1
    fi

    # Giới hạn UTXO tối thiểu của kỷ nguyên Conway (thường khoảng 1 ADA = 1.000.000 Lovelace)
    # Nếu lượng change lẻ nhỏ hơn 1 ADA thì không thể chuyển ngược về ví gửi (gây lỗi bụi giao dịch - dust)
    local min_utxo=1000000
    local final_change=$change
    local final_fee=$fee

    if [ $change -gt 0 ] && [ $change -lt $min_utxo ]; then
        echo "Cảnh báo: Tiền thừa trả lại ($change Lovelace) thấp hơn mức UTXO tối thiểu ($min_utxo Lovelace)."
        echo "Trong Cardano, một UTXO đầu ra cần ít nhất 1 ADA để tránh phát sinh rác."
        echo "Bạn muốn xử lý lượng tiền thừa này như thế nào?"
        echo "1) Tặng luôn tiền thừa ($change Lovelace) này làm thêm phí giao dịch."
        echo "2) Hủy giao dịch."
        read -p "Chọn phương án xử lý (1/2): " change_opt
        
        if [ "$change_opt" == "1" ]; then
            final_fee=$((fee + change))
            final_change=0
            echo "Đã điều chỉnh: change trả về bằng 0, tổng phí giao dịch nâng lên thành $final_fee Lovelace."
        else
            echo "Giao dịch đã bị hủy bỏ."
            rm -f tx.draft pparams.json
            return 1
        fi
    fi

    # Xây dựng giao dịch thô cuối cùng dựa trên các thông số đã tối ưu
    echo "Đang xuất giao dịch thô chính thức..."
    if [ $final_change -gt 0 ]; then
        "$CARDANO_CLI" conway transaction build-raw \
            "${tx_in_args[@]}" \
            --tx-out "$tx_out+$tx_amount_lovelace" \
            --tx-out "$sender_address+$final_change" \
            --fee "$final_fee" \
            --invalid-hereafter "$ttl" \
            --out-file tx.raw
    else
        "$CARDANO_CLI" conway transaction build-raw \
            "${tx_in_args[@]}" \
            --tx-out "$tx_out+$tx_amount_lovelace" \
            --fee "$final_fee" \
            --invalid-hereafter "$ttl" \
            --out-file tx.raw
    fi

    if [ $? -eq 0 ]; then
        echo "Đã xây dựng giao dịch thô thành công và lưu tại 'tx.raw'!"
        
        # Trích xuất chuỗi hex CBOR từ file JSON
        local cbor_hex
        cbor_hex=$(jq -r '.cborHex' tx.raw)

        # Lưu chuỗi hex CBOR kèm tiền tố vào tệp tin tx_raw.txt
        local wallet_out_dir="."
        if [ -n "$SELECTED_WALLET_NAME" ] && [ -d "../offline/wallets/$SELECTED_WALLET_NAME" ]; then
            wallet_out_dir="../offline/wallets/$SELECTED_WALLET_NAME"
        elif [ -n "$SELECTED_WALLET_NAME" ] && [ -d "../offline/$SELECTED_WALLET_NAME" ]; then
            wallet_out_dir="../offline/$SELECTED_WALLET_NAME"
        fi

        echo "TxBodyConway:$cbor_hex" > "$wallet_out_dir/tx_raw.txt"
        echo "Đã lưu chuỗi văn bản giao dịch thô vào tệp: $wallet_out_dir/tx_raw.txt"

        # Tạo mã QR nếu qrencode có sẵn trên máy
        if command -v qrencode &> /dev/null; then
            echo "--------------------------------------------------------"
            echo "MÃ QR GIAO DỊCH THÔ (Quét mã này bằng Máy Offline để ký):"
            qrencode -t ansiutf8 "TxBodyConway:$cbor_hex"
            qrencode -o "$wallet_out_dir/tx_raw_qr.png" "TxBodyConway:$cbor_hex"
            echo "File ảnh QR giao dịch thô được lưu tại: $wallet_out_dir/tx_raw_qr.png"
        else
            echo "Cảnh báo: Không tìm thấy 'qrencode'. Bỏ qua vẽ QR trên Terminal."
        fi

        echo "--------------------------------------------------------"
        echo "CHUỖI HEX CBOR GIAO DỊCH THÔ (Đã lưu vào $wallet_out_dir/tx_raw.txt hoặc copy chuỗi dưới):"
        echo "TxBodyConway:$cbor_hex"
        echo "--------------------------------------------------------"

        # Dọn dẹp các tệp tạm để tránh rác hệ thống
        rm -f tx.draft pparams.json
    else
        echo "Lỗi: Không thể xuất giao dịch thô qua $CARDANO_CLI."
        rm -f tx.draft pparams.json
        return 1
    fi
}

# 3. Ủy thác Stake Pool & DRep (Dự thảo giao dịch ủy thác Conway Era)
delegate_tx() {
    check_cli || return 1

    local wallet_name=""
    read -p "Nhập tên ví Cardano từ máy offline (ví dụ: C2VN): " wallet_name
    wallet_name=$(echo "$wallet_name" | tr -cd '[:alnum:]_-')

    local wallet_dir=""
    if [ -n "$wallet_name" ] && [ -d "../offline/wallets/$wallet_name" ]; then
        wallet_dir="../offline/wallets/$wallet_name"
    elif [ -n "$wallet_name" ] && [ -d "../offline/$wallet_name" ]; then
        wallet_dir="../offline/$wallet_name"
    else
        echo "Lỗi: Không tìm thấy thư mục ví cho '$wallet_name'."
        echo "Vui lòng kiểm tra lại tên ví."
        return 1
    fi

    # Đọc địa chỉ gửi từ payment.addr
    local sender_address=""
    if [ -f "$wallet_dir/payment.addr" ]; then
        sender_address=$(cat "$wallet_dir/payment.addr")
    else
        echo "Lỗi: Không tìm thấy tệp payment.addr tại '$wallet_dir'."
        return 1
    fi

    # Đọc khóa stake.vkey
    local stake_vkey_path="$wallet_dir/stake.vkey"
    if [ ! -f "$stake_vkey_path" ]; then
        echo "Lỗi: Không tìm thấy tệp stake.vkey tại '$wallet_dir'."
        echo "Vui lòng đảm bảo rằng ví này đã được sinh khóa ủy quyền (stake key)."
        return 1
    fi

    # Đọc stake.addr
    local stake_address=""
    if [ -f "$wallet_dir/stake.addr" ]; then
        stake_address=$(cat "$wallet_dir/stake.addr")
    else
        # Tạo stake.addr nếu chưa có
        echo "Đang tạo địa chỉ stake tạm thời..."
        "$CARDANO_CLI" conway stake-address build \
            --stake-verification-key-file "$stake_vkey_path" \
            --out-file "$wallet_dir/stake.addr" \
            $NETWORK_PARAM
        stake_address=$(cat "$wallet_dir/stake.addr")
    fi

    echo "Địa chỉ thanh toán: $sender_address"
    echo "Địa chỉ ủy thác (Stake Address): $stake_address"

    # Kiểm tra trạng thái trên blockchain thông qua Blockfrost
    echo "Đang kiểm tra trạng thái đăng ký của Stake Address trên blockchain..."
    local is_registered
    is_registered=$(bf_check_stake_registered "$stake_address")

    local deposit=0
    if [ "$is_registered" == "true" ]; then
        echo "Trạng thái: ĐÃ ĐĂNG KÝ trên chuỗi. Không cần nộp tiền cọc (Key Deposit)."
    else
        echo "Trạng thái: CHƯA ĐĂNG KÝ trên chuỗi."
        echo "Bạn cần đóng tiền đặt cọc đăng ký khóa (Key Deposit): 2 ADA (2,000,000 Lovelace)."
        echo "Tiền cọc này sẽ được hoàn lại nếu bạn hủy đăng ký (deregister) khóa stake sau này."
        deposit=2000000
    fi

    # Lựa chọn DRep
    echo "--------------------------------------------------------"
    echo "Lựa chọn DRep muốn ủy quyền bầu cử (Conway Governance):"
    echo "1. DRep C2VN (Mặc định) - ID: drep1ygqlu72zwxszcx0kqdzst4k3g6fxx4klwcmpk0fcuujskvg3pmhgs"
    echo "2. Bỏ phiếu trắng / Không biểu quyết (Always Abstain)"
    echo "3. Luôn bất tín nhiệm (Always No Confidence)"
    echo "4. Ủy quyền cho một DRep ID khác"
    read -p "Nhập lựa chọn của bạn (1-4): " drep_choice
    
    local drep_arg=""
    case $drep_choice in
        2)
            drep_arg="--always-abstain"
            echo "Đã chọn: Bỏ phiếu trắng (Always Abstain)"
            ;;
        3)
            drep_arg="--always-no-confidence"
            echo "Đã chọn: Luôn bất tín nhiệm (Always No Confidence)"
            ;;
        4)
            local drep_id=""
            read -p "Nhập DRep ID (Bech32 bắt đầu bằng 'drep1...' hoặc dạng Hex): " drep_id
            if [ -z "$drep_id" ]; then
                echo "DRep ID không được để trống. Hủy thao tác."
                return 1
            fi
            drep_arg="--drep-key-hash $drep_id"
            echo "Đã chọn DRep ID: $drep_id"
            ;;
        *)
            local default_drep="drep1ygqlu72zwxszcx0kqdzst4k3g6fxx4klwcmpk0fcuujskvg3pmhgs"
            drep_arg="--drep-key-hash $default_drep"
            echo "Đã chọn DRep C2VN (Mặc định): $default_drep"
            ;;
    esac

    # Lựa chọn Stake Pool
    echo "--------------------------------------------------------"
    local pool_id="18109d01af0c5c4495a64a9de061ad621156729afc699128c0ceee0e"
    echo "Lựa chọn Stake Pool để ủy thác ADA:"
    echo "1. Pool HADA (Mặc định) - ID: $pool_id"
    echo "2. Nhập Stake Pool ID khác"
    read -p "Nhập lựa chọn của bạn (1-2): " pool_choice

    if [ "$pool_choice" == "2" ]; then
        read -p "Nhập Stake Pool ID (Bech32 'pool1...' hoặc dạng Hex): " custom_pool_id
        if [ -n "$custom_pool_id" ]; then
            pool_id="$custom_pool_id"
        else
            echo "Sử dụng Pool HADA mặc định."
        fi
    fi
    echo "Đã chọn Stake Pool: $pool_id"

    # Tạo file chứng chỉ ủy thác (Certificate)
    echo "--------------------------------------------------------"
    echo "Đang tạo chứng chỉ ủy thác..."
    local cert_file="delegation.cert"

    if [ "$is_registered" == "true" ]; then
        # Chỉ tạo chứng chỉ ủy thác stake và vote
        if ! "$CARDANO_CLI" conway stake-address stake-and-vote-delegation-certificate \
            --stake-verification-key-file "$stake_vkey_path" \
            --stake-pool-id "$pool_id" \
            $drep_arg \
            --out-file "$cert_file"; then
            echo "Lỗi: Không thể tạo chứng chỉ ủy thác."
            return 1
        fi
    else
        # Tạo chứng chỉ đăng ký + ủy thác stake và vote
        if ! "$CARDANO_CLI" conway stake-address registration-stake-and-vote-delegation-certificate \
            --stake-verification-key-file "$stake_vkey_path" \
            --stake-pool-id "$pool_id" \
            $drep_arg \
            --key-reg-deposit-amt "$deposit" \
            --out-file "$cert_file"; then
            echo "Lỗi: Không thể tạo chứng chỉ đăng ký và ủy thác."
            return 1
        fi
    fi
    echo "Đã tạo chứng chỉ ủy thác: $cert_file"

    # Lấy thông tin UTXO để thanh toán phí và đặt cọc
    echo "Đang truy vấn UTXO người gửi từ Blockfrost..."
    local utxos_json
    utxos_json=$(bf_get_utxos "$sender_address")
    if [ $? -ne 0 ] || [ -z "$utxos_json" ]; then
        echo "Truy cập UTXO lỗi hoặc ví không có tiền. Vui lòng kiểm tra lại."
        rm -f "$cert_file"
        return 1
    fi

    local sorted_utxos
    sorted_utxos=$(echo "$utxos_json" | jq -r '.[] | "\(.tx_hash)#\(.tx_index) : \(.amount[] | select(.unit=="lovelace") | .quantity)"')

    if [ -z "$sorted_utxos" ]; then
        echo "Không tìm thấy UTXO nào cho địa chỉ này. Không thể tạo giao dịch."
        rm -f "$cert_file"
        return 1
    fi

    echo "--------------------------------------------------------"
    echo "Danh sách UTXO khả dụng:"
    echo "$sorted_utxos" | nl -w2 -s'. '
    read -p "Nhập số thứ tự UTXO muốn dùng làm Input (ví dụ: '1', '1 3 4', hoặc 'all' để chọn tất cả): " utxo_input

    utxo_input=$(echo "$utxo_input" | tr ',' ' ' | xargs)
    local total_utxos
    total_utxos=$(echo "$sorted_utxos" | wc -l)

    if [ "$utxo_input" = "all" ] || [ "$utxo_input" = "a" ]; then
        utxo_input=$(seq 1 "$total_utxos")
    fi

    if [ -z "$utxo_input" ]; then
        echo "Lựa chọn UTXO không hợp lệ."
        rm -f "$cert_file"
        return 1
    fi

    local tx_in_args=()
    local input_lovelace=0
    local utxo_num
    local has_invalid=false
    local selected_info=""

    for utxo_num in $utxo_input; do
        if ! [[ "$utxo_num" =~ ^[0-9]+$ ]] || [ "$utxo_num" -lt 1 ] || [ "$utxo_num" -gt "$total_utxos" ]; then
            echo "Lựa chọn UTXO thứ tự '$utxo_num' không hợp lệ."
            has_invalid=true
            break
        fi

        local selected_utxo_line
        selected_utxo_line=$(echo "$sorted_utxos" | sed -n "${utxo_num}p")
        
        local utxo_in
        utxo_in=$(echo "$selected_utxo_line" | awk -F' : ' '{print $1}')
        local utxo_lovelace
        utxo_lovelace=$(echo "$selected_utxo_line" | awk -F' : ' '{print $2}')

        tx_in_args+=("--tx-in" "$utxo_in")
        input_lovelace=$((input_lovelace + utxo_lovelace))
        selected_info="$selected_info\n  + $utxo_in ($((utxo_lovelace / 1000000)) ADA)"
    done

    if [ "$has_invalid" = true ] || [ ${#tx_in_args[@]} -eq 0 ]; then
        echo "Lỗi: Không có UTXO hợp lệ nào được chọn."
        rm -f "$cert_file"
        return 1
    fi

    # Kiểm tra xem tổng ADA đầu vào có đủ trả tiền cọc không
    if [ $input_lovelace -le $deposit ]; then
        echo "Lỗi: Số dư đầu vào ($((input_lovelace / 1000000)) ADA) không đủ để chi trả tiền đặt cọc đăng ký khóa ($((deposit / 1000000)) ADA)."
        rm -f "$cert_file"
        return 1
    fi

    # Lấy thông số kỷ nguyên (Epoch parameters) để tính toán phí giao dịch tối thiểu
    echo "Đang tải tham số mạng lưới (Protocol Parameters) từ Blockfrost..."
    bf_get_pparams "pparams.json"
    if [ $? -ne 0 ] || [ ! -f "pparams.json" ]; then
        echo "Tải tham số mạng lưới thất bại."
        rm -f "$cert_file"
        return 1
    fi

    # Lấy slot mới nhất để cấu hình TTL
    echo "Đang lấy số slot hiện tại từ Blockfrost..."
    local latest_slot
    latest_slot=$(bf_get_latest_slot)
    if [ $? -ne 0 ]; then
        echo "Không lấy được slot mới nhất từ Blockfrost."
        rm -f "$cert_file" pparams.json
        return 1
    fi
    local ttl=$((latest_slot + 1000))
    echo "Slot block mới nhất: $latest_slot. Đặt TTL giao dịch là $ttl."

    # Xây dựng giao dịch nháp (draft transaction) để ước tính phí tối thiểu
    echo "Đang tính toán phí giao dịch tối thiểu (Minimum Fee)..."
    "$CARDANO_CLI" conway transaction build-raw \
        "${tx_in_args[@]}" \
        --tx-out "$sender_address+0" \
        --fee 0 \
        --certificate-file "$cert_file" \
        --invalid-hereafter "$ttl" \
        --protocol-params-file pparams.json \
        --out-file tx.draft

    # Tính phí tối thiểu
    local fee_raw
    fee_raw=$("$CARDANO_CLI" conway transaction calculate-min-fee \
        --tx-body-file tx.draft \
        --witness-count 2 \
        --protocol-params-file pparams.json \
        $NETWORK_PARAM)

    if [ $? -ne 0 ] || [ -z "$fee_raw" ]; then
        echo "Lỗi: Không thể tính phí giao dịch."
        rm -f tx.draft pparams.json "$cert_file"
        return 1
    fi

    # Trích xuất giá trị số từ kết quả calculate-min-fee
    local min_fee
    min_fee=$(echo "$fee_raw" | grep -oE '[0-9]+' | head -n 1)
    if [ -z "$min_fee" ]; then
        echo "Lỗi: Không trích xuất được phí giao dịch từ: $fee_raw"
        rm -f tx.draft pparams.json "$cert_file"
        return 1
    fi

    # Cộng thêm đệm an toàn để tránh lỗi FeeTooSmallUTxO
    local safety_buffer=2000
    local final_fee=$((min_fee + safety_buffer))
    echo "Phí tối thiểu ước tính: $min_fee Lovelace. Áp dụng đệm an toàn: $safety_buffer Lovelace. Phí chính thức: $final_fee Lovelace."

    # Tính toán số dư còn dư trả lại cho ví (Change)
    # Change = Input - Deposit - Fee
    local final_change=$((input_lovelace - deposit - final_fee))

    if [ $final_change -lt 1000000 ]; then
        echo "Lỗi: Số dư còn lại sau khi trừ tiền cọc và phí ($((final_change / 1000000)) ADA) nhỏ hơn 1 ADA (min-utxo)."
        echo "Vui lòng chọn thêm UTXO đầu vào để hoàn tất giao dịch."
        rm -f tx.draft pparams.json "$cert_file"
        return 1
    fi

    # Xây dựng giao dịch thô chính thức
    echo "Đang xuất giao dịch thô chính thức..."
    if ! "$CARDANO_CLI" conway transaction build-raw \
        "${tx_in_args[@]}" \
        --tx-out "$sender_address+$final_change" \
        --fee "$final_fee" \
        --certificate-file "$cert_file" \
        --invalid-hereafter "$ttl" \
        --out-file tx.raw; then
        echo "Lỗi: Không thể xuất giao dịch thô qua $CARDANO_CLI."
        rm -f tx.draft pparams.json "$cert_file"
        return 1
    fi

    # Lưu chuỗi hex CBOR kèm tiền tố vào tệp tin tx_raw.txt
    local cbor_hex
    cbor_hex=$(jq -r '.cborHex' tx.raw)

    echo "TxBodyConwayDelegation:$cbor_hex" > "$wallet_dir/tx_raw.txt"
    echo "Đã lưu chuỗi văn bản giao dịch thô vào tệp: $wallet_dir/tx_raw.txt"

    # Tạo mã QR
    if command -v qrencode &> /dev/null; then
        echo "--------------------------------------------------------"
        echo "MÃ QR GIAO DỊCH ỦY THÁC THÔ (Quét mã này bằng Máy Offline để ký):"
        qrencode -t ansiutf8 "TxBodyConwayDelegation:$cbor_hex"
        qrencode -o "$wallet_dir/tx_raw_qr.png" "TxBodyConwayDelegation:$cbor_hex"
        echo "File ảnh QR giao dịch thô được lưu tại: $wallet_dir/tx_raw_qr.png"
    else
        echo "Cảnh báo: Không tìm thấy 'qrencode'. Bỏ qua vẽ QR trên Terminal."
    fi

    echo "--------------------------------------------------------"
    echo "CHUỖI HEX CBOR GIAO DỊCH THÔ (Đã lưu vào $wallet_dir/tx_raw.txt):"
    echo "TxBodyConwayDelegation:$cbor_hex"
    echo "--------------------------------------------------------"

    # Lưu lại tên ví đang thao tác để các menu sau tự động nhận diện
    SELECTED_WALLET_NAME="$wallet_name"

    # Dọn dẹp
    rm -f tx.draft pparams.json "$cert_file" tx.raw
}

# 4. Đọc QR giao dịch đã ký và thực hiện gửi lên Blockchain
submit_signed_tx() {
    echo "--------------------------------------------------------"
    echo "Lựa chọn phương thức nạp giao dịch đã ký:"
    echo "1. Quét mã QR bằng Webcam trực tiếp (cần cài đặt zbar-tools & webcam)"
    echo "2. Đọc mã QR từ tệp ảnh (cần cài đặt zbar-tools)"
    echo "3. Dán thủ công chuỗi hex CBOR đã ký"
    echo "4. Đọc chuỗi hex đã ký từ tệp văn bản (mặc định: tx_signed.txt)"
    read -p "Lựa chọn phương thức (1-4): " input_choice

    local signed_hex=""
    case $input_choice in
        1)
            if ! command -v zbarcam &> /dev/null; then
                echo "Lỗi: 'zbarcam' chưa được cài đặt."
                return 1
            fi
            echo "Đang khởi động webcam... Hướng webcam vào mã QR đã ký."
            signed_hex=$(zbarcam --raw --oneshot 2>/dev/null)
            ;;
        2)
            if ! command -v zbarimg &> /dev/null; then
                echo "Lỗi: 'zbarimg' chưa được cài đặt."
                return 1
            fi
            read -p "Nhập đường dẫn đến tệp ảnh chứa mã QR: " img_path
            if [ ! -f "$img_path" ]; then
                echo "Không tìm thấy tệp ảnh: $img_path"
                return 1
            fi
            signed_hex=$(zbarimg --raw -q "$img_path" 2>/dev/null)
            ;;
        3)
            read -p "Nhập chuỗi hex CBOR đã ký (Bắt đầu bằng hoặc bỏ qua TxConway:): " signed_hex
            ;;
        4)
            local wallet_out_dir="."
            if [ -n "$SELECTED_WALLET_NAME" ] && [ -d "../offline/wallets/$SELECTED_WALLET_NAME" ]; then
                wallet_out_dir="../offline/wallets/$SELECTED_WALLET_NAME"
            elif [ -n "$SELECTED_WALLET_NAME" ] && [ -d "../offline/$SELECTED_WALLET_NAME" ]; then
                wallet_out_dir="../offline/$SELECTED_WALLET_NAME"
            fi
            
            local txt_path=""
            read -p "Nhập đường dẫn tệp văn bản [tx_signed.txt hoặc $wallet_out_dir/tx_signed.txt]: " txt_path
            if [ -z "$txt_path" ]; then
                if [ -f "tx_signed.txt" ]; then
                    txt_path="tx_signed.txt"
                elif [ -f "$wallet_out_dir/tx_signed.txt" ]; then
                    txt_path="$wallet_out_dir/tx_signed.txt"
                else
                    txt_path="tx_signed.txt"
                fi
            fi
            if [ ! -f "$txt_path" ]; then
                echo "Lỗi: Không tìm thấy tệp: $txt_path"
                return 1
            fi
            signed_hex=$(cat "$txt_path")
            ;;
        *)
            echo "Lựa chọn không hợp lệ."
            return 1
            ;;
    esac

    # Loại bỏ các khoảng trắng hoặc xuống dòng không mong muốn
    signed_hex=$(echo "$signed_hex" | tr -d '\r\n[:space:]')
    
    # Loại bỏ tiền tố nhận dạng TxConway: nếu có
    signed_hex=${signed_hex#TxConway:}

    if [[ -z "$signed_hex" ]]; then
        echo "Lỗi: Không nhận được dữ liệu giao dịch."
        return 1
    fi

    # Kiểm tra tính hợp lệ của mã hex
    if [[ ! "$signed_hex" =~ ^[0-9a-fA-F]+$ ]]; then
        echo "Lỗi: Định dạng CBOR hex đã ký không hợp lệ (không phải hệ thập lục phân)."
        return 1
    fi

    echo "Đang tái dựng cấu trúc file giao dịch đã ký..."
    local env_type
    env_type=$(get_envelope_type_signed)
    cat <<EOF > tx.signed
{
    "type": "$env_type",
    "description": "",
    "cborHex": "$signed_hex"
}
EOF

    echo "Đang tiến hành gửi giao dịch lên mạng lưới thông qua Blockfrost..."
    local response
    response=$(bf_submit_tx "$signed_hex")

    local clean_response
    clean_response=$(echo "$response" | tr -d '"')

    # Nếu gửi thành công, Blockfrost sẽ trả lại mã hash giao dịch dài 64 ký tự hex
    if [[ "$clean_response" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "--------------------------------------------------------"
        echo "GIAO DỊCH ĐÃ ĐƯỢC GỬI THÀNH CÔNG!"
        echo "Mã Hash giao dịch (txid): $clean_response"
        echo "Bạn có thể kiểm tra trạng thái tại Cardanoscan:"
        echo "https://preprod.cardanoscan.io/transaction/$clean_response"
        echo "--------------------------------------------------------"
        
        # Dọn dẹp tệp tin giao dịch đã hoàn thành
        rm -f tx.raw tx.signed
    else
        echo "--------------------------------------------------------"
        echo "GỬI GIAO DỊCH THẤT BẠI!"
        echo "Phản hồi chi tiết từ Blockfrost:"
        echo "$response"
        echo "--------------------------------------------------------"
        rm -f tx.signed
        return 1
    fi
}

# Vòng lặp giao diện điều hướng chính của máy Online
while true; do
    echo "========================================================"
    echo "Menu Ví Cardano Trực Tuyến - Online Wallet (Hot)"
    echo "========================================================"
    echo "1. Tra cứu Số dư / UTXO"
    echo "2. Khởi tạo Giao dịch Thô (Xuất QR / Chuỗi Hex)"
    echo "3. Đọc mã QR Giao dịch Đã Ký & Submit lên mạng lưới"
    echo "4. Ủy thác (Stake Pool & DRep)"
    echo "5. Thoát"
    read -p "Nhập lựa chọn của bạn (1-5): " choice

    case $choice in
        1)
            check_balance
            ;;
        2)
            build_tx
            ;;
        3)
            submit_signed_tx
            ;;
        4)
            delegate_tx
            ;;
        5)
            echo "Đang thoát chương trình..."
            exit 0
            ;;
        *)
            echo "Lựa chọn không tồn tại."
            ;;
    esac
    echo ""
done
