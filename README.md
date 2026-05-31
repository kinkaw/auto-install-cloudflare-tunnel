# Cloudflare Tunnel Manager สำหรับ Windows

โปรเจกต์นี้มีสคริปต์ `cloudflare-tunnel-manager.bat` สำหรับจัดการ Cloudflare Tunnel บน Windows ผ่าน Docker Desktop โดยไม่ต้องติดตั้ง `cloudflared` ลงเครื่องโดยตรง สคริปต์จะเรียกใช้งาน image `cloudflare/cloudflared` และเก็บไฟล์ tunnel/config ทั้งหมดไว้ในโฟลเดอร์ข้อมูลที่กำหนด

> สคริปต์เป็นไฟล์ `.bat` สำหรับ Windows และมี PowerShell ฝังอยู่ภายในไฟล์เดียว เพื่อให้จัดการ path, validation และเมนู interactive ได้เสถียรขึ้น

## ความต้องการก่อนใช้งาน

- Windows 10/11 หรือ Windows Server ที่รัน Docker ได้
- PowerShell 5 ขึ้นไป
- Docker Desktop หรือ Docker Engine ที่สั่ง `docker info` ได้
- บัญชี Cloudflare ที่มีสิทธิ์สร้าง Tunnel และ DNS route

## วิธีเริ่มใช้งาน

เปิด Command Prompt หรือ PowerShell ในโฟลเดอร์โปรเจกต์ แล้วรัน:

```bat
cloudflare-tunnel-manager.bat
```

ถ้าต้องการกำหนดโฟลเดอร์เก็บข้อมูลเอง:

```bat
cloudflare-tunnel-manager.bat --base-dir D:\cloudflared-data
```

หรือกำหนดผ่าน environment variable:

```bat
set CFTM_HOME=D:\cloudflared-data
set CLOUDFLARED_IMAGE=cloudflare/cloudflared:latest
cloudflare-tunnel-manager.bat
```

## โครงสร้างไฟล์ที่สคริปต์สร้าง

ค่าเริ่มต้นจะสร้างโฟลเดอร์ `cloudflared-data` ในตำแหน่งที่รันสคริปต์:

```text
cloudflared-data/
  docker-compose.yml
  tunnels.tsv
  <tunnel-slug>/
    cert.pem
    <tunnel-id>.json
    config.yaml
    .tunnel-meta
  backups/
  nginx-templates/
```

ไฟล์สำคัญ:

- `cert.pem` และ `<tunnel-id>.json` คือ credentials ของ Cloudflare Tunnel ควรเก็บเป็นความลับ
- `config.yaml` คือ ingress rule ของ tunnel
- `docker-compose.yml` ใช้ start/stop/restart container ของ tunnel
- `tunnels.tsv` เป็น registry ภายในเครื่อง
- `backups/` เก็บไฟล์ backup แบบ `.zip`

## เมนูหลัก

เมื่อรันสคริปต์ จะมีเมนู:

1. Docker setup help
2. Cloudflare Login
3. Create Tunnel
4. List Tunnels
5. Delete Tunnel
6. Create DNS Routes
7. Generate config.yaml
8. Generate docker-compose.yml
9. Start Tunnel
10. Stop Tunnel
11. Restart Tunnel
12. View Logs
13. Health Dashboard
14. Backup / Restore
15. Nginx Template Generator
16. Validation

## Workflow แนะนำ

1. ติดตั้งและเปิด Docker Desktop
2. รัน `cloudflare-tunnel-manager.bat`
3. เลือก `2) Cloudflare Login` เพื่อ login และสร้าง `cert.pem`
4. เลือก `3) Create Tunnel` เพื่อสร้าง tunnel ใหม่
5. ให้สคริปต์สร้าง `config.yaml` และ DNS route ตาม prompt
6. เลือก `8) Generate docker-compose.yml`
7. เลือก `9) Start Tunnel`
8. ตรวจสอบด้วย `13) Health Dashboard`, `12) View Logs` หรือ `16) Validation`

## ตัวอย่าง ingress service

ค่าที่รับได้ใน `config.yaml` เช่น:

```text
http://host.docker.internal:80
http://host.docker.internal:3000
https://host.docker.internal:8443
ssh://host.docker.internal:22
tcp://host.docker.internal:5432
http_status:404
hello_world
```

บน Docker Desktop สำหรับ Windows สามารถใช้ `host.docker.internal` เพื่อให้ container เรียก service ที่รันบนเครื่อง host ได้

## Backup และ Restore

เลือก `14) Backup / Restore`

- Backup จะสร้างไฟล์ `.zip` ใน `cloudflared-data/backups/`
- สคริปต์จะถามว่าจะรวม credential files (`cert.pem` และ `*.json`) หรือไม่
- ถ้ารวม credentials ให้เก็บไฟล์ backup ไว้ในที่ปลอดภัย เพราะสามารถใช้เข้าถึง tunnel ได้

## Nginx Template

เมนู `15) Nginx Template Generator` จะสร้างไฟล์ตัวอย่าง Nginx reverse proxy ใน:

```text
cloudflared-data/nginx-templates/
```

นำไฟล์นี้ไปปรับใช้กับ Nginx server ได้ตาม environment ของคุณ

## คำสั่งช่วยเหลือ

```bat
cloudflare-tunnel-manager.bat --help
cloudflare-tunnel-manager.bat --version
```

## ตรวจสอบว่าใช้ไฟล์เวอร์ชันล่าสุด

ถ้ารันแล้วเจอ error ในไฟล์ชั่วคราวลักษณะ `Unexpected token 'Embedded'` หรือเห็นข้อความ `$raw.IndexOf($marker)` ใน error แปลว่ายังใช้ไฟล์ `.bat` เวอร์ชันเก่าอยู่ ให้ดาวน์โหลด/คัดลอก `cloudflare-tunnel-manager.bat` ล่าสุดทับไฟล์เดิม แล้วเช็คว่า:

```bat
cloudflare-tunnel-manager.bat --version
```

ควรแสดง `1.0.1` หรือใหม่กว่า และบรรทัดบน ๆ ของไฟล์ควรมี:

```bat
rem cftm-wrapper-version=1.0.1
```

## ข้อควรระวัง

- อย่า commit หรือแชร์โฟลเดอร์ `cloudflared-data` หากมี credentials จริง
- ตรวจสอบ DNS และ hostname ให้ถูกต้องก่อนสร้าง route
- ถ้า Docker Desktop ยังไม่พร้อม สคริปต์จะไม่สามารถเรียก `cloudflared` ได้
- การลบ tunnel แบบ remote จะเรียกคำสั่ง `cloudflared tunnel delete` ผ่าน Docker และควรตรวจสอบชื่อ tunnel ให้แน่ใจก่อนยืนยัน
