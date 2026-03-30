---
name: devstack-setup
description: DevStack 환경을 Lima VM으로 설치/관리하는 가이드. "devstack 설치", "devstack setup", "openstack 환경 구축", "멀티노드 설치" 요청 시 트리거.
---

# DevStack Setup Guide for Claude

macOS Apple Silicon에서 Lima VM 기반 OpenStack DevStack 환경을 설치한다.
싱글(all-in-one)과 멀티노드(controller + compute x2) 두 가지 모드를 지원한다.

## 사전 확인

사용자에게 모드를 물어본다:
- **single**: API 테스트 전용 (Cold Migration + Confirm/Revert만 가능)
- **multi**: Live Migration, Evacuate 포함 전체 테스트

## 설치 도구 위치

```
nexttui/devstack/
├── ds                     — 운영 CLI
├── single/devstack.yaml   — 싱글 모드 Lima 설정
└── multi/
    ├── devstack-ctrl.yaml — controller
    ├── devstack-cp1.yaml  — compute 1
    └── devstack-cp2.yaml  — compute 2
```

또는 독립 repo: `https://github.com/bluejayA/devstack-lima`

## 설치 절차 (Multi-Node)

### Phase 1: Prerequisites

```bash
# 확인
brew --version
limactl --version
file /opt/socket_vmnet/bin/socket_vmnet  # symlink이면 안됨, 실제 바이너리여야 함
```

없으면 설치:
```bash
brew install lima socket_vmnet
sudo mkdir -p /opt/socket_vmnet/bin
sudo cp /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet /opt/socket_vmnet/bin/socket_vmnet
sudo brew services start socket_vmnet
limactl sudoers | sudo tee /etc/sudoers.d/lima
```

> **주의**: `ln -s`는 Lima가 거부한다. 반드시 `cp`로 복사.
> **주의**: `sudo` 명령은 사용자에게 `!` prefix로 실행하도록 안내.

### Phase 2: VM 생성

```bash
./devstack/ds up multi
```

### Phase 3: IP 확인 + Configure

```bash
./devstack/ds ips
# ctrl=192.168.105.2  cp1=192.168.105.3  cp2=192.168.105.4 (예시)

./devstack/ds configure-compute devstack-cp1 <ctrl_ip>
./devstack/ds configure-compute devstack-cp2 <ctrl_ip>
```

### Phase 4: stack.sh (순차 실행, 총 60-90분)

**반드시 controller 먼저, 완료 후 compute 노드.**

```bash
./devstack/ds stack devstack-ctrl   # 30-45분 (백그라운드 실행 권장)
./devstack/ds stack devstack-cp1    # 25-30분
./devstack/ds stack devstack-cp2    # 25-30분
```

> compute 노드는 controller의 MySQL/RabbitMQ에 접속하므로 controller가 완전히 완료된 후 실행.
> cp1, cp2는 병렬 실행 가능.

### Phase 5: Post-Setup (필수)

```bash
./devstack/ds post-setup multi
```

이 명령이 수행하는 작업:
1. `nova-cpu.conf`에서 `cpu_mode=host-passthrough` → `cpu_mode=custom` + `cpu_model=cortex-a72`
2. `libvirtd-tcp.socket` 활성화 (포트 16509)
3. `nova-compute` 재시작
4. `nova-manage cell_v2 discover_hosts` (cell mapping)

### Phase 6: Validate

```bash
./devstack/ds validate multi
```

**All checks passed** 가 나오면 완료.

## 설치 절차 (Single)

```bash
./devstack/ds up single
./devstack/ds stack devstack          # 30-45분
./devstack/ds validate single
```

post-setup 불필요.

## 알려진 이슈와 해결법

### Neutron 시작 실패 — OVN mechanism driver

**증상**: `Geneve max_header_size set too low for OVN`
**원인**: 최신 DevStack이 기본 OVN 사용. local.conf에 OVS가 명시되어 있어야 함.
**해결**: Lima YAML의 local.conf에 이미 포함되어 있음:
```
Q_ML2_PLUGIN_MECHANISM_DRIVERS=openvswitch,l2population
```
이 설정이 없는 local.conf를 사용하면 발생.

### libvirtd 시작 실패 — `--listen` unsupported

**증상**: `libvirtd.service: Main process exited, code=exited, status=6/NOTCONFIGURED`
**원인**: Ubuntu 24.04 libvirt 10.0은 `--listen` 대신 socket activation 사용.
**해결**: `ds post-setup multi`가 `libvirtd-tcp.socket`을 활성화.

### 인스턴스 ERROR — host-passthrough

**증상**: `CPU mode 'host-passthrough' for aarch64 qemu domain on aarch64 host is not supported`
**원인**: ARM QEMU에서 host-passthrough 불가. DevStack 기본값이 이것.
**주의**: 설정 파일이 `/etc/nova/nova-cpu.conf`이다. `/etc/nova/nova.conf`가 아님!
**해결**: `ds post-setup multi`가 `cpu_mode=custom`, `cpu_model=cortex-a72`로 수정.

### Hypervisor 0대 — cell mapping 누락

**증상**: `openstack hypervisor list`가 비어있지만 `openstack compute service list`에는 nova-compute가 up.
**원인**: compute 호스트가 Nova cell에 매핑되지 않음.
**해결**: `ds post-setup multi`가 `nova-manage cell_v2 discover_hosts` 실행.

### Hypervisor disabled — libvirtd 재시작 후

**증상**: hypervisor list 비어있고, compute service Status가 `disabled`.
**원인**: libvirtd 중단 시 nova-compute가 자동 disabled 전환.
**해결**:
```bash
# controller에서
openstack compute service set --enable <host> nova-compute
```

## VM 재시작 후 서비스 복구

VM을 `ds down`/`ds up`한 후:

```bash
./ds ssh <vm>
sudo -iu stack
cd /opt/stack/devstack
./rejoin-stack.sh
```

멀티노드의 경우 controller 먼저, 이후 compute 노드.

## 검증 판정 기준

`ds validate multi` 결과:
- **Stage 1**: 3 VM running + 3 ping + 2 libvirt TCP → 전부 PASS
- **Stage 2**: 5 compute services up + 6 network agents + 2 hypervisors → 전부 PASS
- **Stage 3**: cirros 인스턴스 생성 → ACTIVE → 삭제 → PASS

하나라도 FAIL이면 위 "알려진 이슈" 섹션에서 매칭되는 증상을 찾아 해결.

## clouds.yaml (nexttui 연동)

multi-node 설치 후:
```yaml
clouds:
  devstack-multi:
    auth:
      auth_url: http://<ctrl_ip>:5000/v3
      project_name: admin
      username: admin
      password: secret
      user_domain_name: Default
      project_domain_name: Default
    region_name: RegionOne
    identity_api_version: 3
```

`<ctrl_ip>`는 `ds ips`로 확인.

## 리소스 스펙

| VM | CPU | RAM | Disk |
|----|-----|-----|------|
| devstack-ctrl | 2 | 8GB | 40GB |
| devstack-cp1 | 2 | 4GB | 30GB |
| devstack-cp2 | 2 | 4GB | 30GB |
| **합계** | **6** | **16GB** | **100GB** |

호스트 최소 요구: 20GB+ RAM, 6+ CPU, 110GB+ 디스크 여유.
