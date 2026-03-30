# DevStack on Lima

macOS (Apple Silicon)에서 Lima VM으로 OpenStack DevStack 환경을 구축하는 자동화 도구.

## Quick Start

```bash
git clone https://github.com/bluejayA/devstack-lima.git
cd devstack-lima
./setup.sh multi    # 또는 ./setup.sh single
```

30-60분 후 OpenStack이 준비됩니다.

## Modes

| Mode | VMs | Use Case |
|------|-----|----------|
| `single` | 1 (all-in-one, 12GB) | 기본 API 테스트, Cold Migration only |
| `multi` | 3 (ctrl 8GB + cp1 4GB + cp2 4GB) | Live Migration, Evacuate 테스트 |

## Requirements

- macOS (Apple Silicon)
- 20GB+ RAM (multi) / 16GB+ RAM (single)
- Homebrew (자동 설치)

## Commands

```bash
./ds status               # VM 상태
./ds up single|multi      # VM 시작
./ds down single|multi    # VM 중지
./ds ssh <vm>             # SSH 접속
./ds validate single|multi # 설치 검증
./ds post-setup multi     # ARM/libvirt 후처리
```

## Architecture

```
                          ┌─────────────────────┐
                          │   devstack-ctrl      │
                          │   (Controller)       │
    macOS Host            │   keystone, nova-api │
    ┌──────────┐          │   neutron, glance    │
    │ nexttui  │── API ──>│   mysql, rabbitmq    │
    └──────────┘          └──────────┬──────────-┘
                                     │
                          ┌──────────┴──────────┐
                          │                      │
                   ┌──────┴──────┐       ┌──────┴──────┐
                   │ devstack-cp1│       │ devstack-cp2│
                   │ (Compute 1) │       │ (Compute 2) │
                   │ nova-compute│<─TCP─>│ nova-compute│
                   │ libvirtd    │ 16509 │ libvirtd    │
                   └─────────────┘       └─────────────┘
```

## Detailed Guide

See [INSTALL.md](INSTALL.md) for manual setup, troubleshooting, and nexttui integration.
