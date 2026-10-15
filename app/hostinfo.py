"""스캔 대상 서버의 호스트명·IP 수집 (표준 라이브러리만, 폐쇄망 대응)."""
import socket
import subprocess


def _ip_by_route() -> str:
    # UDP connect는 패킷을 보내지 않고 라우팅만 결정 — 기본 경로가 있으면 대표 IP를 얻는다
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    finally:
        s.close()


def _ip_by_hostname(hostname: str) -> str:
    for ip in socket.gethostbyname_ex(hostname)[2]:
        if not ip.startswith("127."):
            return ip
    return ""


def _ip_by_command() -> str:
    # RHEL: `hostname -I`는 루프백을 제외한 주소 목록을 출력한다
    out = subprocess.check_output(["hostname", "-I"], stderr=subprocess.DEVNULL, timeout=3)
    for ip in out.decode("utf-8", "ignore").split():
        if "." in ip and not ip.startswith("127."):
            return ip
    return ""


def get_host_info() -> dict:
    hostname = socket.gethostname()
    ip = ""
    for probe in (_ip_by_route, lambda: _ip_by_hostname(hostname), _ip_by_command):
        try:
            ip = probe()
        except Exception:
            ip = ""
        if ip and not ip.startswith("127.") and ip != "0.0.0.0":
            break
        ip = ""
    return {"hostname": hostname, "ip": ip}
