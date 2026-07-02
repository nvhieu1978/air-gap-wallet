#!/bin/bash

# Các hàm trợ giúp gọi API Blockfrost phục vụ cho Ví Cardano Online (Hot)

# Hàm kiểm tra cấu hình kết nối tới Blockfrost
check_blockfrost() {
    # Kiểm tra xem API Key đã được cấu hình trong config.env chưa
    if [ -z "$BLOCKFROST_API_KEY" ]; then
        echo "Lỗi: BLOCKFROST_API_KEY chưa được thiết lập trong config.env." >&2
        return 1
    fi
    # Kiểm tra xem Endpoint URL của Blockfrost đã được cấu hình chưa
    if [ -z "$BLOCKFROST_URL" ]; then
        echo "Lỗi: BLOCKFROST_URL chưa được thiết lập trong config.env." >&2
        return 1
    fi
    return 0
}

# Lấy danh sách UTXO của một địa chỉ ví cụ thể
# Cách dùng: bf_get_utxos <địa_chỉ_ví>
bf_get_utxos() {
    check_blockfrost || return 1
    local address=$1
    local url="${BLOCKFROST_URL}/addresses/${address}/utxos"
    
    # Thực hiện gọi API của Blockfrost bằng curl với header project_id là API Key
    local response
    response=$(curl -s -H "project_id: $BLOCKFROST_API_KEY" "$url")
    
    # Kiểm tra xem Blockfrost có trả về mã lỗi (status_code) hoặc phản hồi rỗng không
    if echo "$response" | grep -q "status_code" || [ -z "$response" ]; then
        echo "Lỗi khi lấy UTXO từ Blockfrost: $response" >&2
        return 1
    fi
    # Trả về kết quả JSON nhận được
    echo "$response"
}

# Lấy số slot block mới nhất để phục vụ tính toán thời gian hết hạn (TTL) của giao dịch
# Cách dùng: bf_get_latest_slot
bf_get_latest_slot() {
    check_blockfrost || return 1
    local url="${BLOCKFROST_URL}/blocks/latest"
    
    # Gọi API thông tin block mới nhất
    local response
    response=$(curl -s -H "project_id: $BLOCKFROST_API_KEY" "$url")
    
    # Kiểm tra tính hợp lệ của phản hồi
    if echo "$response" | grep -q "status_code" || [ -z "$response" ]; then
        echo "Lỗi khi lấy thông tin block mới nhất: $response" >&2
        return 1
    fi
    
    # Dùng jq trích xuất trường slot của block mới nhất
    local slot
    slot=$(echo "$response" | jq -r '.slot')
    if [ "$slot" == "null" ] || [ -z "$slot" ]; then
        echo "Lỗi: Số slot bị null hoặc trống" >&2
        return 1
    fi
    echo "$slot"
}

# Tải về các tham số giao thức (protocol parameters) và định dạng lại khớp với cấu trúc của cardano-cli
# Cách dùng: bf_get_pparams <tên_file_đầu_ra.json>
bf_get_pparams() {
    check_blockfrost || return 1
    local out_file=$1
    local url="${BLOCKFROST_URL}/epochs/latest/parameters"
    
    # Lấy thông số kỷ nguyên (epoch) hiện tại
    local response
    response=$(curl -s -H "project_id: $BLOCKFROST_API_KEY" "$url")
    
    if echo "$response" | grep -q "status_code" || [ -z "$response" ]; then
        echo "Lỗi khi lấy tham số epoch: $response" >&2
        return 1
    fi
    
    # Xác định đường dẫn của file mẫu pparams_template.json cùng thư mục
    local template_file="$(dirname "${BASH_SOURCE[0]}")/pparams_template.json"
    if [ ! -f "$template_file" ]; then
        echo "Lỗi: Không tìm thấy tệp mẫu tham số giao thức tại $template_file" >&2
        return 1
    fi

    # Sử dụng jq để hợp nhất tham số mới nhận được từ Blockfrost vào file mẫu
    # Định nghĩa hàm helper safe_tonumber để chuyển đổi dữ liệu an toàn tránh lỗi jq
    jq --argjson bf "$response" '
      def safe_tonumber: if . == null or . == "" then 0 else tostring | tonumber end;
      .txFeeFixed = (($bf.min_fee_b // .txFeeFixed) | safe_tonumber) |
      .txFeePerByte = (($bf.min_fee_a // .txFeePerByte) | safe_tonumber) |
      .utxoCostPerByte = (($bf.coins_per_utxo_size // $bf.coins_per_utxo_word // $bf.min_utxo // .utxoCostPerByte) | safe_tonumber) |
      .executionUnitPrices.priceMemory = (($bf.price_mem // .executionUnitPrices.priceMemory) | safe_tonumber) |
      .executionUnitPrices.priceSteps = (($bf.price_step // .executionUnitPrices.priceSteps) | safe_tonumber) |
      .collateralPercentage = (($bf.collateral_percent // .collateralPercentage) | safe_tonumber) |
      .maxBlockBodySize = (($bf.max_block_size // .maxBlockBodySize) | safe_tonumber) |
      .maxBlockHeaderSize = (($bf.max_block_header_size // .maxBlockHeaderSize) | safe_tonumber) |
      .maxTxSize = (($bf.max_tx_size // .maxTxSize) | safe_tonumber) |
      .maxValueSize = (($bf.max_val_size // .maxValueSize) | safe_tonumber) |
      .stakeAddressDeposit = (($bf.key_deposit // .stakeAddressDeposit) | safe_tonumber) |
      .stakePoolDeposit = (($bf.pool_deposit // .stakePoolDeposit) | safe_tonumber) |
      .protocolVersion.major = (($bf.protocol_major // .protocolVersion.major) | safe_tonumber) |
      .protocolVersion.minor = (($bf.protocol_minor // .protocolVersion.minor) | safe_tonumber) |
      .maxBlockExecutionUnits.memory = (($bf.max_block_ex_mem // .maxBlockExecutionUnits.memory) | safe_tonumber) |
      .maxBlockExecutionUnits.steps = (($bf.max_block_ex_steps // .maxBlockExecutionUnits.steps) | safe_tonumber) |
      .maxTxExecutionUnits.memory = (($bf.max_tx_ex_mem // .maxTxExecutionUnits.memory) | safe_tonumber) |
      .maxTxExecutionUnits.steps = (($bf.max_tx_ex_steps // .maxTxExecutionUnits.steps) | safe_tonumber) |
      .maxCollateralInputs = (($bf.max_collateral_inputs // .maxCollateralInputs) | safe_tonumber) |
      .minPoolCost = (($bf.min_pool_cost // .minPoolCost) | safe_tonumber) |
      .poolRetireMaxEpoch = (($bf.e_max // .poolRetireMaxEpoch) | safe_tonumber)
    ' "$template_file" > "$out_file"
}

# Gửi giao dịch đã ký (signed transaction) lên blockchain
# Cách dùng: bf_submit_tx <chuỗi_hex_giao_dịch_đã_ký>
bf_submit_tx() {
    check_blockfrost || return 1
    local cbor_hex=$1
    local url="${BLOCKFROST_URL}/tx/submit"
    
    # Do Blockfrost yêu cầu dữ liệu gửi lên là binary định dạng application/cbor
    # Chúng ta dùng Python chuyển đổi chuỗi hex thành binary thô và truyền qua pipeline cho curl POST
    local response
    response=$(python3 -c "import sys; sys.stdout.buffer.write(bytes.fromhex('$cbor_hex'))" | \
               curl -s -X POST \
                    -H "project_id: $BLOCKFROST_API_KEY" \
                    -H "Content-Type: application/cbor" \
                    --data-binary @- \
                    "$url")
    
    echo "$response"
}
