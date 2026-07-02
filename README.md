# Cardano Air-Gap Wallet (Ví Cardano Ngoại Tuyến)

Dự án này chia các kịch bản Bash quản lý tài sản Cardano trước đây thành hai phần độc lập: **Online (Hot)** và **Offline (Cold)**. Hệ thống cho phép bạn xây dựng giao dịch trực tuyến, ký giao dịch ngoại tuyến (bảo mật khóa riêng tư bằng mật khẩu) và gửi giao dịch lên mạng lưới mà không bao giờ để lộ khóa riêng tư (Private Key) ra internet.

Hệ thống hỗ trợ quản lý **nhiều ví độc lập** thông qua cấu trúc phân mục theo tên ví (ví dụ: `wallets/C2VN/`).

Dữ liệu giao dịch được chuyển đổi qua lại giữa hai máy tính bằng **Mã QR** (hoặc tệp văn bản/chuỗi hex nếu không có camera hoặc truyền qua USB).

---

## Cấu trúc Thư mục

```text
16.air-gap-wallet/
├── README.md                    # Tài liệu hướng dẫn sử dụng
├── PROCESS_AND_SECURITY.md      # Quy trình bảo mật & luồng dữ liệu
│
├── online/                      # Phần chạy trên Máy tính Online (Hot)
│   ├── config.env               # Cấu hình Blockfrost API & Mạng lưới
│   ├── blockfrost_helper.sh     # Hàm bổ trợ gọi API Blockfrost
│   └── online_main.sh           # Menu chính phần Online (Tạo Tx, Submit)
│
└── offline/                     # Phần chạy trên Máy tính Offline (Cold)
    ├── config.env               # Cấu hình Mạng lưới (Ngoại tuyến)
    ├── wallet-generate.sh       # Kịch bản tạo mới/khôi phục ví
    ├── offline_main.sh          # Menu chính phần Offline (Ký Tx ngoại tuyến)
    └── wallets/                 # Thư mục lưu trữ các ví đã tạo
        └── <WALLET_NAME>/       # Thư mục riêng của từng ví (Ví dụ: C2VN)
            ├── payment.addr     # Địa chỉ nhận tiền công khai
            ├── stake.addr       # Địa chỉ ủy quyền stake
            ├── payment.vkey     # Khóa xác minh thanh toán công khai
            ├── stake.vkey       # Khóa xác minh ủy quyền công khai
            ├── payment.pub      # Khóa công khai thô
            ├── payment.skey.enc # Khóa ký thanh toán ĐÃ MÃ HÓA
            ├── stake.skey.enc   # Khóa ký ủy quyền ĐÃ MÃ HÓA
            ├── phrase.prv.enc   # Cụm 24 từ khôi phục ĐÃ MÃ HÓA
            ├── tx_raw.txt       # File giao dịch thô
            ├── tx_raw_qr.png    # Ảnh QR giao dịch thô
            ├── tx_signed.txt    # File giao dịch đã ký
            └── tx_signed_qr.png # Ảnh QR giao dịch đã ký
```

---

## Yêu cầu Hệ thống & Công cụ

Đảm bảo các công cụ sau được cài đặt trên các máy tương ứng. Trên Ubuntu, các công cụ quét và tạo mã QR mặc định sẽ không có sẵn, bạn cần cài đặt bằng lệnh:

```bash
sudo apt update
sudo apt install -y zbar-tools qrencode
```

### Máy Online (Hot):
*   `curl` & `jq` (Dùng để truy vấn dữ liệu từ API Blockfrost).
*   `cardano-cli` (Phiên bản Conway trở lên - dùng để xây dựng cấu trúc giao dịch raw). https://github.com/IntersectMBO/cardano-node/releases/tag/11.0.1
*   `qrencode` (Dùng để chuyển giao dịch raw thành mã QR hiển thị trên Terminal).
*   *Tùy chọn:* `zbar-tools` (Gồm `zbarcam` và `zbarimg` để quét mã QR đã ký từ máy Offline).

### Máy Offline (Cold):
*   `cardano-address` & `cardano-cli` (Dùng để tạo khóa, địa chỉ và ký giao dịch).
*   `openssl` (Hỗ trợ mã hóa khóa riêng tư).
*   `qrencode` (Chuyển giao dịch đã ký thành mã QR).
*   *Tùy chọn:* `zbar-tools` (Quét mã QR giao dịch raw từ máy Online).

---

## Cơ chế Bảo mật khóa riêng tư

1.  **Mã hóa AES-256-CBC với PBKDF2**: Tất cả các tệp chứa khóa riêng tư (`phrase.prv`, `payment.skey`, `stake.skey`) đều được mã hóa bằng OpenSSL với mật khẩu người dùng tự chọn. Số vòng lặp băm PBKDF2 được đặt ở mức cực kỳ bảo mật là `100,000` lần.
2.  **Xóa sạch dấu vết trên RAM Disk**: Sau khi tạo khóa hoặc ký xong giao dịch, các tệp chứa khóa không mã hóa trong bộ nhớ đệm `/dev/shm` (RAM Disk) sẽ lập tức bị ghi đè nhiều lần và xóa vĩnh viễn khỏi ổ cứng bằng lệnh `shred -u` để tránh bị khôi phục dữ liệu:
    ```bash
    shred -u /dev/shm/cardano-airgap-sign-XXXX/payment.skey.tmp
    ```
3.  **Cô lập và Phân vùng**: Mỗi ví được lưu trong một thư mục con riêng biệt dưới `offline/wallets/<WALLET_NAME>/`. Điều này ngăn chặn việc nhầm lẫn hoặc ghi đè khóa giữa các ví khác nhau.

---

## Quy trình Thực hiện Giao dịch (6 Bước)

### Bước 1: Tạo/Khôi phục ví (Offline)
1.  Truy cập thư mục `offline/`.
2.  Chạy `./offline_main.sh` và chọn **Option 1 (Create / Restore Wallet)**.
3.  Nhập tên ví (ví dụ: `C2VN`). Thư mục `wallets/C2VN/` sẽ được tự động tạo.
4.  Lựa chọn tạo mới hoặc nhập cụm 24 từ khôi phục.
5.  Nhập mật khẩu bảo vệ ví.
6.  Hệ thống sẽ sinh ra địa chỉ ví và các tệp mã hóa khóa riêng tư `.enc` trong thư mục `wallets/C2VN/`.

### Bước 2: Cấu hình API Blockfrost (Online)
1.  Tạo tệp cấu hình `online/config.env` bằng cách sao chép từ tệp ví dụ mẫu:
    ```bash
    cp online/config.env.example online/config.env
    ```
2.  Đăng ký tài khoản và lấy Project ID miễn phí tại [Blockfrost.io](https://blockfrost.io).
3.  Mở tệp `online/config.env` và điền khóa của bạn vào biến:
    ```bash
    BLOCKFROST_API_KEY="preprod_xxxxxxxxxxxxxxxx"
    ```

### Bước 3: Kiểm tra số dư & UTXO (Online)
1.  Chạy `./online_main.sh` trên máy online và chọn **Option 1 (Check Balance / UTXOs)**.
2.  Nhập tên ví Cardano từ máy offline (ví dụ: `C2VN`). Hệ thống sẽ tự động tìm kiếm địa chỉ ví tại `../offline/wallets/C2VN/payment.addr`.
3.  Xem danh sách các UTXO hiện tại và tổng số dư khả dụng.

### Bước 4: Tạo giao dịch trực tuyến (Online)
1.  Chọn **Option 2 (Build Raw Transaction)** trên menu `online_main.sh`.
2.  Nhập tên ví `C2VN` để tự động xác định địa chỉ gửi.
3.  Chọn số thứ tự UTXO muốn tiêu dùng từ danh sách UTXO hiển thị.
4.  Nhập địa chỉ ví người nhận và số ADA muốn chuyển.
5.  Kịch bản sẽ tự động tạo giao dịch thô và xuất ra file `tx_raw.txt` và `tx_raw_qr.png` trực tiếp vào thư mục ví `../offline/wallets/C2VN/` (nếu chạy trên cùng workspace) hoặc tại thư mục hiện hành.

### Bước 5: Ký giao dịch ngoại tuyến (Offline)
1.  Chạy `./offline_main.sh` trên máy offline, chọn **Option 2 (Sign Raw Transaction)**.
2.  Nhập tên ví thực hiện ký (ví dụ: `C2VN`).
3.  Chọn phương thức nhập giao dịch: Quét trực tiếp bằng Webcam, Đọc file ảnh mã QR, Dán chuỗi văn bản, hoặc **chọn Option 4 để đọc trực tiếp từ tệp văn bản** (mặc định sẽ tải từ `wallets/C2VN/tx_raw.txt`).
4.  Nhập mật khẩu ví để giải mã khóa và ký giao dịch.
5.  Hệ thống ký giao dịch và tự động lưu tệp đã ký vào `wallets/C2VN/tx_signed.txt` và mã QR `wallets/C2VN/tx_signed_qr.png`.

### Bước 6: Đọc giao dịch đã ký & Gửi lên Blockchain (Online)
1.  Chọn **Option 3 (Read Signed Transaction & Submit)** trên menu `online_main.sh`.
2.  Hệ thống hỏi tên ví, hãy nhập `C2VN`.
3.  Chọn **Option 4 để đọc trực tiếp từ tệp văn bản** (mặc định sẽ kiểm tra `../offline/wallets/C2VN/tx_signed.txt`).
4.  Giao dịch sẽ được truyền lên mạng lưới Cardano qua Blockfrost API. Khi thành công, liên kết Cardanoscan sẽ hiển thị để bạn theo dõi.

---

## Quy trình Ủy thác Stake Pool & Bỏ phiếu DRep (Conway Era)

Trong kỷ nguyên Conway, Cardano gộp việc đăng ký khóa stake, ủy quyền biểu quyết DRep và ủy thác Stake Pool thành các chứng chỉ thống nhất. Dự án hỗ trợ quy trình này hoàn toàn ngoại tuyến:

### Các bước thực hiện:

1.  **Khởi tạo Giao dịch Ủy thác (Online)**:
    *   Chạy `./online_main.sh` trên máy online và chọn **Option 4 (Ủy thác Stake Pool & DRep)**.
    *   Nhập tên ví (ví dụ: `C2VN`). Hệ thống tự động đọc khóa `stake.vkey` và địa chỉ stake `stake.addr`.
    *   Hệ thống gọi API Blockfrost để kiểm tra xem khóa ủy thác đã được đăng ký trên chuỗi chưa:
        *   **Chưa đăng ký**: Hệ thống tự động tính thêm 2 ADA tiền cọc khóa (Key Deposit) và chọn tạo chứng chỉ `registration-stake-and-vote-delegation-certificate`.
        *   **Đã đăng ký**: Chỉ cần tạo chứng chỉ ủy quyền `stake-and-vote-delegation-certificate` không mất tiền cọc.
    *   Chọn phương án ủy quyền **DRep** (Mặc định là bỏ phiếu trắng *Always Abstain* để bảo vệ quyền lợi nếu bạn chưa chọn được DRep phù hợp).
    *   Chọn **Stake Pool** để nhận phần thưởng (Mặc định là **Pool HADA** - ID: `18109d01af0c5c4495a64a9de061ad621156729afc699128c0ceee0e`).
    *   Chọn UTXO thanh toán phí và tiền đặt cọc (nếu có).
    *   Hệ thống xuất giao dịch thô chứa chứng chỉ ủy thác vào `wallets/C2VN/tx_raw.txt` và hiển thị mã QR.

2.  **Ký giao dịch ngoại tuyến (Offline)**:
    *   Chạy `./offline_main.sh` trên máy offline và chọn **Option 2 (Sign Raw Transaction)**.
    *   Nhập tên ví `C2VN` và mật khẩu.
    *   Hệ thống sẽ **tự động phát hiện** tệp `stake.skey.enc` bên cạnh `payment.skey.enc`.
    *   Hệ thống tiến hành giải mã an toàn cả hai khóa thô vào RAM Disk (`/dev/shm`), thực hiện ký đồng thời bằng cả khóa thanh toán và khóa ủy quyền (vì giao dịch ủy thác yêu cầu chữ ký của khóa Stake để xác thực quyền sở hữu).
    *   Sau khi ký, các khóa thô lập tức bị xóa sạch bằng `shred` để bảo mật tuyệt đối. Giao dịch đã ký được xuất ra `wallets/C2VN/tx_signed.txt` dưới dạng QR/Hex.

3.  **Gửi giao dịch đã ký (Online)**:
    *   Thực hiện tương tự **Bước 6** thông thường để gửi giao dịch đã ký lên mạng lưới thông qua Blockfrost.
