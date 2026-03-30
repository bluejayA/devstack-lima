# DevStack Installation Guide

nexttui 개발/테스트를 위한 OpenStack DevStack 환경 구축 가이드.
싱글(all-in-one)과 멀티노드(controller + compute x2) 두 가지 모드를 지원한다.

## 목차

1. [호스트 요구사항](#1-호스트-요구사항)
2. [사전 설치](#2-사전-설치)
3. [싱글 모드 설치](#3-싱글-모드-설치)
4. [멀티노드 모드 설치](#4-멀티노드-모드-설치)
5. [설치 검증](#5-설치-검증)
6. [nexttui 연동](#6-nexttui-연동)
7. [운영 명령어](#7-운영-명령어)
8. [트러블슈팅](#8-트러블슈팅)

---

## 1. 호스트 요구사항

| 항목 | 싱글 모드 | 멀티노드 모드 |
|------|-----------|--------------|
| OS | macOS (Apple Silicon) | macOS (Apple Silicon) |
| CPU | 4+ 코어 | 6+ 코어 |
| RAM | 16GB+ (VM 12GB) | 20GB+ (VM 합계 16GB) |
| Disk | 70GB+ 여유 | 110GB+ 여유 |

### VM 리소스 배분

**싱글 모드:**

| VM | CPU | RAM | Disk |
|----|-----|-----|------|
| devstack | 4 | 12GB | 60GB |

**멀티노드 모드:**

| VM | CPU | RAM | Disk | 역할 |
|----|-----|-----|------|------|
| devstack-ctrl | 2 | 8GB | 40GB | Controller (API/DB/MQ) |
| devstack-cp1 | 2 | 4GB | 30GB | Compute 1 |
| devstack-cp2 | 2 | 4GB | 30GB | Compute 2 |
| **합계** | **6** | **16GB** | **100GB** | |

---

## 2. 사전 설치

### 2.1 Homebrew

이미 설치되어 있다면 스킵.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2.2 Lima

Lima는 macOS에서 Linux VM을 실행하는 도구.

```bash
brew install lima
```

설치 확인:

```bash
limactl --version
# lima version 1.x.x
```

### 2.3 socket_vmnet (멀티노드 필수)

멀티노드 모드에서 VM 간 L2 네트워크 통신을 위해 필요하다. 싱글 모드만 사용할 경우 스킵 가능.

```bash
brew install socket_vmnet
```

바이너리를 Lima가 찾는 경로에 복사:

```bash
sudo mkdir -p /opt/socket_vmnet/bin
sudo cp /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet /opt/socket_vmnet/bin/socket_vmnet
```

> **주의:** symlink(`ln -s`)는 Lima가 보안상 거부한다. 반드시 `cp`로 복사할 것.

서비스 시작:

```bash
sudo brew services start socket_vmnet
```

Lima sudoers 설정 (VM 시작 시 sudo 비밀번호 입력 생략):

```bash
limactl sudoers | sudo tee /etc/sudoers.d/lima
```

설치 확인:

```bash
# 바이너리 확인
file /opt/socket_vmnet/bin/socket_vmnet
# → Mach-O 64-bit executable arm64

# sudoers 확인
limactl sudoers >/dev/null && echo "OK"
```

---

## 3. 싱글 모드 설치

가장 간단한 구성. OpenStack 전체 서비스가 하나의 VM에서 실행된다.
Migration 테스트는 Cold Migration + Confirm/Revert만 가능하다 (Live Migration 불가).

### 3.1 VM 생성 및 시작

```bash
cd devstack/
./ds up single
```

### 3.2 DevStack 설치

```bash
./ds stack devstack
```

15-30분 소요. 완료되면 `This is your host IP address: ...` 메시지가 출력된다.

### 3.3 검증

```bash
./ds validate single
```

---

## 4. 멀티노드 모드 설치

Controller 1대 + Compute 2대 구성. Live Migration, Cold Migration, Evacuate 모두 테스트 가능.

### 4.1 VM 생성

```bash
cd devstack/
./ds up multi
```

3대의 VM이 순차적으로 생성된다.

### 4.2 IP 확인

```bash
./ds ips
# Multi-node VM IPs (lima0):
#   devstack-ctrl        192.168.105.2
#   devstack-cp1         192.168.105.3
#   devstack-cp2         192.168.105.4
```

IP는 DHCP로 할당되므로 환경마다 다를 수 있다.

### 4.3 Compute 노드에 Controller IP 주입

```bash
./ds configure-compute devstack-cp1 <ctrl_ip>
./ds configure-compute devstack-cp2 <ctrl_ip>
```

예시:

```bash
./ds configure-compute devstack-cp1 192.168.105.2
./ds configure-compute devstack-cp2 192.168.105.2
```

### 4.4 DevStack 설치 (순차 실행)

**반드시 Controller 먼저 설치한 후 Compute 노드를 설치한다.**

```bash
# 1. Controller (30-45분)
./ds stack devstack-ctrl

# 2. Compute 노드 (각 25-30분)
./ds stack devstack-cp1
./ds stack devstack-cp2
```

> Compute 노드는 Controller의 MySQL/RabbitMQ에 접속하므로, Controller가 완전히 설치된 후에 실행해야 한다.

### 4.5 Post-Setup (필수)

ARM Mac에서 발생하는 호환성 이슈를 자동 수정한다. **3대 모두 stack.sh가 완료된 후** 실행한다.

```bash
./ds post-setup multi
```

이 명령이 수행하는 작업:
1. **CPU 모드 수정**: `host-passthrough` → `custom` + `cortex-a72` (ARM QEMU 호환)
2. **libvirt TCP socket**: compute 노드 간 live migration을 위한 TCP 16509 포트 활성화
3. **nova-compute 재시작**: 설정 변경 반영
4. **Cell mapping**: compute 호스트를 Nova cell에 등록 (`nova-manage cell_v2 discover_hosts`)

### 4.6 검증

```bash
./ds validate multi
```

모든 항목이 PASS이면 설치 완료.

---

## 5. 설치 검증

`ds validate` 명령은 3단계 검증을 자동 수행한다:

| 단계 | 검증 내용 |
|------|----------|
| **Stage 1: Infrastructure** | VM 실행 상태, VM 간 ping, libvirt TCP 연결 (멀티노드) |
| **Stage 2: Services** | Compute/Network 서비스 상태, Hypervisor 등록 수 |
| **Stage 3: Instance** | cirros 이미지로 인스턴스 생성 → ACTIVE 확인 → 삭제 |

```bash
# 싱글 모드
./ds validate single

# 멀티노드 모드 (기본값)
./ds validate multi
```

---

## 6. nexttui 연동

### 6.1 clouds.yaml 설정

DevStack 설치 후 `~/.config/openstack/clouds.yaml`에 엔드포인트를 추가한다.

**싱글 모드** (포트포워딩으로 localhost 접근):

```yaml
clouds:
  devstack:
    auth:
      auth_url: http://localhost:5000/v3
      project_name: admin
      username: admin
      password: secret
      user_domain_name: Default
      project_domain_name: Default
    region_name: RegionOne
    identity_api_version: 3
```

**멀티노드 모드** (Controller IP 직접 접근):

```yaml
clouds:
  devstack-multi:
    auth:
      auth_url: http://192.168.105.2:5000/v3
      project_name: admin
      username: admin
      password: secret
      user_domain_name: Default
      project_domain_name: Default
    region_name: RegionOne
    identity_api_version: 3
```

> 멀티노드에서 Controller IP가 다를 수 있다. `./ds ips`로 확인할 것.

### 6.2 nexttui 실행

```bash
cd /path/to/nexttui
cargo run
```

admin으로 로그인하면 서버 목록에서 Host 컬럼이 표시되고, Migration 키바인딩(M/C/Y/N/E)을 사용할 수 있다.

---

## 7. 운영 명령어

```bash
./ds up single|multi          # VM 시작
./ds down single|multi        # VM 중지
./ds status                   # 전체 VM 상태
./ds ssh <vm-name>            # VM SSH 접속
./ds stack <vm-name>          # stack.sh 실행
./ds post-setup multi         # ARM/libvirt/cell 후처리 (멀티노드)
./ds ips                      # 멀티노드 IP 확인
./ds validate [single|multi]  # 설치 검증
./ds configure-compute <vm> <ctrl_ip>  # Compute에 Controller IP 설정
```

### DevStack 서비스 재시작

VM을 중지(`ds down`)했다가 다시 시작(`ds up`)한 후에는 DevStack 서비스를 재시작해야 한다:

```bash
./ds ssh <vm-name>
sudo -iu stack
cd /opt/stack/devstack
./rejoin-stack.sh
```

---

## 8. 트러블슈팅

### socket_vmnet 관련

**증상:** `paths.socketVMNet has to be installed`

```bash
# 바이너리 존재 확인
file /opt/socket_vmnet/bin/socket_vmnet

# 없으면 복사
sudo mkdir -p /opt/socket_vmnet/bin
sudo cp /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet /opt/socket_vmnet/bin/socket_vmnet
```

**증상:** `socketVMNet is a symlink`

Lima는 보안상 symlink를 거부한다. 기존 symlink를 제거하고 실제 파일을 복사:

```bash
sudo rm /opt/socket_vmnet/bin/socket_vmnet
sudo cp /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet /opt/socket_vmnet/bin/socket_vmnet
```

### Compute 노드가 Controller에 접속 실패

**증상:** `stack.sh` 실행 중 MySQL/RabbitMQ 연결 에러

```bash
# Controller IP가 올바르게 설정되었는지 확인
./ds ssh devstack-cp1 -- cat /opt/stack/devstack/local.conf | grep SERVICE_HOST

# Compute에서 Controller로 접속 가능한지 확인
./ds ssh devstack-cp1 -- ping -c 2 <ctrl_ip>
./ds ssh devstack-cp1 -- nc -zv <ctrl_ip> 3306   # MySQL
./ds ssh devstack-cp1 -- nc -zv <ctrl_ip> 5672   # RabbitMQ
```

### Hypervisor 0대 등록 (compute service는 up)

**증상:** `openstack compute service list`에는 nova-compute가 보이지만 `openstack hypervisor list`가 비어있음

**원인:** Compute 호스트가 Nova cell에 매핑되지 않았음

```bash
# 수동 cell discovery
./ds ssh devstack-ctrl -- sudo -iu stack bash -c \
  'source /opt/stack/devstack/openrc admin admin && nova-manage cell_v2 discover_hosts --verbose'

# 또는 post-setup이 이 작업을 자동 수행
./ds post-setup multi
```

### Hypervisor가 disabled 상태

**증상:** `openstack hypervisor list`가 비어있고, compute service의 Status가 `disabled`

**원인:** libvirtd 재시작 시 nova-compute가 자동으로 자신을 disabled로 전환

```bash
# 서비스 enable
./ds ssh devstack-ctrl -- sudo -iu stack bash -c \
  'source /opt/stack/devstack/openrc admin admin && \
   openstack compute service set --enable lima-devstack-cp1 nova-compute && \
   openstack compute service set --enable lima-devstack-cp2 nova-compute'
```

### Live Migration 실패 — libvirt 연결 거부

**증상:** `Connection refused` on port 16509

**원인:** Ubuntu 24.04 libvirt 10.0은 `--listen` 플래그를 지원하지 않음. socket activation 사용 필요.

```bash
# libvirt TCP 소켓 활성화
./ds ssh devstack-cp1 -- sudo bash -c '
  systemctl stop libvirtd
  systemctl enable --now libvirtd-tcp.socket
  systemctl start libvirtd
'

# 연결 테스트
./ds ssh devstack-cp1 -- virsh -c qemu+tcp://<cp2_ip>/system list
./ds ssh devstack-cp2 -- ss -tlnp | grep 16509

# 또는 post-setup이 이 작업을 자동 수행
./ds post-setup multi
```

### 인스턴스 ERROR — CPU mode 'host-passthrough' unsupported

**증상:** 인스턴스가 ERROR 상태. 로그에 `CPU mode 'host-passthrough' for aarch64 qemu domain on aarch64 host is not supported by hypervisor`

**원인:** ARM Mac + QEMU 에뮬레이션에서 host-passthrough 불가. DevStack이 기본으로 설정하는 값.

**주의:** DevStack은 `nova-cpu.conf`를 사용한다. `/etc/nova/nova.conf`가 아님.

```bash
# 현재 설정 확인 — nova-cpu.conf를 확인할 것
./ds ssh devstack-cp1 -- grep "cpu_mode" /etc/nova/nova-cpu.conf

# 수정
./ds ssh devstack-cp1 -- sudo sed -i \
  's/cpu_mode = host-passthrough/cpu_mode = custom\ncpu_model = cortex-a72/' \
  /etc/nova/nova-cpu.conf
./ds ssh devstack-cp1 -- sudo systemctl restart devstack@n-cpu

# 또는 post-setup이 이 작업을 자동 수행
./ds post-setup multi
```

### 인스턴스 ERROR — virt_type 문제

**증상:** 인스턴스 ERROR, 로그에 KVM 관련 에러

```bash
# virt_type 확인 — qemu여야 함 (kvm 아님)
./ds ssh devstack-cp1 -- grep virt_type /etc/nova/nova-cpu.conf
# virt_type = qemu

# 아니면 수정 후 nova-compute 재시작
./ds ssh devstack-cp1 -- sudo sed -i 's/virt_type = kvm/virt_type = qemu/' /etc/nova/nova-cpu.conf
./ds ssh devstack-cp1 -- sudo systemctl restart devstack@n-cpu
```

### OVN mechanism driver 에러

**증상:** stack.sh 중 Neutron 시작 실패. 로그에 `Geneve max_header_size set too low for OVN`

**원인:** 최신 DevStack이 기본으로 OVN을 사용. local.conf에서 명시적으로 OVS를 설정해야 함.

```ini
# local.conf에 반드시 포함
Q_AGENT=openvswitch
Q_ML2_PLUGIN_MECHANISM_DRIVERS=openvswitch,l2population
Q_ML2_TENANT_NETWORK_TYPE=vxlan
disable_service ovn-northd ovn-controller q-ovn-metadata-agent
```
