# pds-claude-setup-in-class

Script cài nhanh **Claude Code (Claude CLI)** trên máy lab RMIT (Windows, đăng nhập tài khoản sinh viên `s<ID>`), để không mất thời gian setup AI trong giờ kiểm tra (course cho phép dùng AI).

## Nội dung repo

| File | Vai trò |
|---|---|
| `setup-claude.ps1` | Script chính (Windows PowerShell 5.1 và PowerShell 7) |
| `setup-claude.cmd` | Launcher: double-click hoặc chạy từ cmd/PowerShell, tự bypass Execution Policy cho riêng lần chạy đó |
| `README.md` | Hướng dẫn này |

## Script làm gì

1. **Hỏi student ID**: chỉ nhập số, không có chữ `s` (ví dụ `4029308`). Lỡ gõ `s4029308` thì script tự bỏ chữ `s`. Nếu đang đăng nhập bằng tài khoản `sXXXXXXX`, chỉ cần bấm Enter để dùng luôn ID đó.
2. **Kiểm tra môi trường**: tài khoản Windows có khớp `s<ID>` không, Execution Policy, Node.js (>= 18), npm, thư mục npm global (`npm config get prefix`) có ghi được không và có trong PATH không, kết nối tới `registry.npmjs.org`, `api.anthropic.com`, `claude.ai`, proxy, và Claude đã được cài sẵn chưa.
   Mỗi vấn đề in ra dạng `[WARN]` / `[FAIL]` kèm dòng `Fix:` gợi ý cách sửa.
3. **Sửa môi trường** (luôn hỏi trước khi sửa): đặt Execution Policy `RemoteSigned` cho user hiện tại, và trả npm prefix về `%APPDATA%\npm` nếu prefix cũ không ghi được.
4. **Cài Claude Code**: `npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code`.
   Với npm 12 thì phải có `--allow-scripts`, vì npm 12 chặn `postinstall` nên file chạy `claude` không được tạo. Với npm cũ hơn, script cài bình thường; nếu thấy cảnh báo bị chặn script thì tự cài lại kèm cờ đó.
   Nếu cài bằng npm thất bại hoặc máy không có Node.js, script đề nghị chuyển sang native installer chính thức (`irm https://claude.ai/install.ps1 | iex`).
5. **PATH**: thêm thư mục npm global (và `%USERPROFILE%\.local\bin` nếu dùng native installer) vào **User PATH**, có kiểm tra trùng và giữ nguyên các biến `%...%` sẵn có. Đồng thời cập nhật PATH của cửa sổ đang mở để dùng được ngay, không cần mở lại.
6. **Xác minh**: chạy `claude --version`, rồi thử trong một cửa sổ PowerShell *mới* để chắc rằng lần sau gõ `claude` là chạy.
7. **Tóm tắt**: liệt kê mọi vấn đề kèm cách sửa, đường dẫn file log, và hỏi có muốn mở `claude` luôn không.

Chạy lại bao nhiêu lần cũng được: bước nào đã xong thì script bỏ qua.

## Cách chạy trên máy trường

### Bước 0: Đưa repo về máy

Chọn một cách:

```powershell
# Cách A: máy có git
cd $HOME\Desktop
git clone <URL-repo-cua-ban> pds-claude-setup-in-class
cd pds-claude-setup-in-class
```

```powershell
# Cách B: tải file ZIP từ GitHub (Code > Download ZIP), giải nén rồi:
cd $HOME\Downloads\pds-claude-setup-in-class-main
Get-ChildItem -Recurse | Unblock-File   # bỏ đánh dấu "tải từ Internet" để PowerShell không chặn
```

```powershell
# Cách C: không tải file, chạy thẳng từ GitHub (repo phải public)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/<github-user>/pds-claude-setup-in-class/main/setup-claude.ps1)))
```

### Bước 1: Chạy script

**Cách 1, dễ nhất:** double-click `setup-claude.cmd` trong File Explorer.

**Cách 2, từ PowerShell** (mở Start, gõ `PowerShell`, Enter; đứng trong thư mục repo):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-claude.ps1
```

**Cách 3, nếu Group Policy của trường chặn luôn cả `-ExecutionPolicy Bypass`:**

```powershell
& ([scriptblock]::Create((Get-Content .\setup-claude.ps1 -Raw)))
```

Script sẽ hỏi:

```text
Enter your student ID without the leading "s" (example: 4029308) [Enter = 4029308]:
```

Gõ ID (ví dụ `4029308`) rồi Enter. Ở những câu hỏi `[Y/n]` hoặc `[y/N]` sau đó, bấm Enter là chọn đáp án viết hoa (mặc định); trả lời `y` (hoặc `c`) là đồng ý, `n` là không.

### Tham số tuỳ chọn

| Tham số | Ý nghĩa |
|---|---|
| `-StudentId 4029308` | Truyền ID luôn, không bị hỏi |
| `-CheckOnly` | Chỉ kiểm tra môi trường, không cài và không thay đổi gì |
| `-Force` | Cài lại hoặc cập nhật kể cả khi `claude` đã chạy được |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-claude.ps1 -StudentId 4029308 -CheckOnly
setup-claude.cmd -StudentId 4029308 -Force
```

### Bước 2: Dùng Claude

```powershell
cd "$HOME\Desktop\a2"     # thư mục làm bài
claude                    # nếu PowerShell chặn: claude.cmd
```

- Lần đầu chạy, Claude mở trình duyệt để đăng nhập (Claude Pro/Max hoặc Anthropic Console). Nếu trình duyệt không tự mở, copy URL hiện trong terminal rồi dán vào trình duyệt.
- Kiểm tra tình trạng cài đặt: `claude doctor`.
- **Trước khi rời máy lab:** gõ `/logout` trong Claude, vì đây là máy dùng chung.

## Lỗi thường gặp và cách sửa

Script tự nhận diện những lỗi dưới đây và in ra `Fix:`. Bảng này để bạn tự sửa tay khi cần.

| Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|
| `npm warn install-scripts ... @anthropic-ai/claude-code (postinstall: node install.cjs)` | npm 12 chặn script `postinstall`, nên `claude` không được tạo | `npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code` |
| `claude : The term 'claude' is not recognized...` | Thư mục npm global (`npm config get prefix`, thường là `C:\Users\s<ID>\AppData\Roaming\npm`) chưa có trong PATH, hoặc chưa có `claude.cmd` vì postinstall bị chặn | Chạy lại script (bước 5 tự thêm PATH), hoặc làm tay theo khối lệnh bên dưới bảng |
| `... cannot be loaded because running scripts is disabled on this system` | Execution Policy đang là `Restricted`, nên PowerShell không chạy được `claude.ps1` / `npm.ps1` | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force`. Nếu Group Policy khoá: gõ `claude.cmd` / `npm.cmd`, hoặc dùng Command Prompt |
| `EPERM` / `EACCES` khi `npm install -g` | Tài khoản sinh viên không có quyền ghi vào thư mục prefix | `npm config set prefix "$env:APPDATA\npm"` rồi cài lại |
| `EBUSY` / `resource busy or locked` | Claude đang chạy nên file bị khoá | Đóng mọi cửa sổ claude (`Stop-Process -Name claude`), rồi cài lại |
| `ETIMEDOUT`, `ENOTFOUND`, `ECONNRESET` | Mất mạng hoặc mạng trường cần proxy | Kiểm tra mạng; nếu có proxy: `npm config set https-proxy http://HOST:PORT` |
| `SELF_SIGNED_CERT_IN_CHAIN`, `UNABLE_TO_GET_ISSUER_CERT` | Mạng trường kiểm tra (inspect) HTTPS | Xin IT chứng chỉ gốc rồi `npm config set cafile <file.pem>`. Cách tạm (kém an toàn): `npm config set strict-ssl false`, xong việc thì `npm config delete strict-ssl` |
| `EINTEGRITY`, `ENOTEMPTY` | Cache npm hỏng hoặc lần cài trước bị dở dang | `npm cache clean --force` rồi cài lại |
| Script chạy xong nhưng cửa sổ khác (VS Code) vẫn báo không có `claude` | PATH chỉ được đọc lúc cửa sổ mở | Đóng **tất cả** terminal và VS Code rồi mở lại |
| Script báo `logged in as 'X', not 's<ID>'` | Gõ nhầm ID hoặc đăng nhập nhầm tài khoản | Chạy lại và gõ đúng ID, hoặc đăng xuất rồi vào bằng tài khoản sinh viên |

Thêm PATH bằng tay (làm điều script tự làm ở bước 5):

```powershell
$npmPath  = npm.cmd config get prefix
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$npmPath*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$npmPath", "User")
}
$env:Path += ";$npmPath"
claude --version
```

## Log

Mỗi lần chạy, script ghi log vào `%TEMP%\claude-setup-<thời gian>.log` (đường dẫn in ở đầu và cuối lúc chạy). Log của npm nằm trong `%LOCALAPPDATA%\npm-cache\_logs`.

## Lưu ý

- Máy lab có thể xoá profile khi đăng xuất. Khi đó mỗi buổi chạy lại script một lần là xong, các bước đã làm sẽ được bỏ qua.
- Script không lưu và không gửi student ID đi đâu. ID chỉ dùng để kiểm tra bạn đang đăng nhập đúng tài khoản.
- Tuân thủ quy định của course về việc dùng AI và ghi nguồn (attribution) khi nộp bài.
