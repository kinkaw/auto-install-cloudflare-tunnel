# auto-install-cloudflare-tunnel

เครื่องมือแบบ interactive ที่เขียนด้วย Bash สำหรับช่วยติดตั้งและจัดการ
Cloudflare Tunnel หลายรายการผ่าน Docker ให้ใช้งานง่ายตั้งแต่เริ่มต้นจนพร้อมใช้งานจริง

## เริ่มใช้งานอย่างรวดเร็ว

```bash
chmod +x cloudflare-tunnel-manager.sh
./cloudflare-tunnel-manager.sh
```

หากต้องการกำหนดโฟลเดอร์เก็บข้อมูลเอง สามารถใช้ `--base-dir` ได้:

```bash
./cloudflare-tunnel-manager.sh --base-dir /home/admin/server/cloudflared
```

## ฟีเจอร์หลัก

- ติดตั้ง Docker แบบ optional สำหรับ Linux server ที่ใช้ apt
- Login Cloudflare ผ่าน Docker image ทางการ `cloudflare/cloudflared`
- สร้าง ดูรายการ และลบ Tunnel
- สร้าง DNS Route ได้ทั้ง hostname เดียวหรือหลาย hostname
- สร้าง `config.yaml` โดยรองรับหลาย ingress hostname ต่อหนึ่ง Tunnel
- สร้าง `docker-compose.yml` รวมทุก Tunnel ไว้ในไฟล์เดียว
- Start, Stop, Restart และดู Logs ของ Tunnel
- Health Dashboard สำหรับตรวจสถานะ Docker, Compose, containers, disk usage และ service status
- Backup และ Restore ไฟล์ที่ script สร้างขึ้น
- สร้าง Nginx reverse proxy template
- Validation สำหรับ hostname, service URL, cloudflared ingress config และ Docker Compose
- รองรับหลาย Tunnel, หลายโดเมน และหลาย Cloudflare account โดยแยก credential ตามโฟลเดอร์

## โครงสร้างไฟล์ที่ถูกสร้าง

โดยค่าเริ่มต้น script จะสร้างและเก็บไฟล์ runtime ไว้ใน `cloudflared-data/`:

```text
cloudflared-data/
  docker-compose.yml
  tunnels.tsv
  devth/
    cert.pem
    <tunnel-id>.json
    config.yaml
  wanyud/
    cert.pem
    <tunnel-id>.json
    config.yaml
  backups/
  nginx-templates/
```

โฟลเดอร์ `cloudflared-data/` ถูก ignore จาก git เพราะอาจมี Cloudflare credentials
เช่น `cert.pem`, `<tunnel-id>.json` และไฟล์ที่สร้างเฉพาะสำหรับแต่ละ server

## วิธีใช้งานทั่วไป

1. รัน script
2. เลือก **Install Docker** หากเครื่องยังไม่ได้ติดตั้ง Docker
3. เลือก **Cloudflare Login** สำหรับ account หรือ tunnel folder ที่ต้องการ
4. เลือก **Create Tunnel**
5. สร้าง `config.yaml` เมื่อ script ถาม
6. สร้าง DNS Route เมื่อ script ถาม
7. สร้าง `docker-compose.yml`
8. Start tunnel service
9. ตรวจสอบสถานะผ่าน Health Dashboard และ Logs

script นี้ออกแบบแบบ Docker-first ดังนั้นไม่จำเป็นต้องติดตั้ง `cloudflared`
ลงบน host โดยตรง

## การรองรับหลาย Cloudflare account

script รองรับหลาย Cloudflare account โดยแยก credential ตามโฟลเดอร์ เช่น:

```text
cloudflared-data/
  account-a/
    cert.pem
    <tunnel-id>.json
    config.yaml
  account-b/
    cert.pem
    <tunnel-id>.json
    config.yaml
```

แต่ละโฟลเดอร์สามารถ login ด้วย Cloudflare account คนละบัญชีได้ และเมื่อต้องสร้าง
Tunnel หรือ DNS Route ให้เลือกโฟลเดอร์ของ account นั้นให้ถูกต้อง
