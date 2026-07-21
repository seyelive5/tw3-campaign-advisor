# TW3 캠페인 어드바이저 (Campaign Advisor)

Total War: WARHAMMER III 용 **플레이어 보조 모드**. 캠페인 맵에 "지금 할 일 추천" 버튼을 추가하고,
누르면 현재 캠페인 상태(재정·영토·군대·인접 팩션·위협)를 읽어 다음 행동을 추천한다.

> **Phase 1 = 읽기 전용.** 아무 행동도 자동 실행하지 않는다. 추천 점수 로직/LLM/write-back은 뒤 단계.

## 현재 환경 (실측 확정)
| 항목 | 값 |
|---|---|
| 게임 버전 | WARHAMMER III **8.1.1.0** |
| Lua 런타임 | **5.1** (tw_autogen 기준) |
| API ground truth | `chadvandy/tw_autogen` → `C:\Users\veria\tools\tw_autogen\output\wh3` |
| 패킹 툴 | RPFM (`C:\Users\veria\tools\rpfm`) — CLI 확보 여부 확인 중 |
| 테스트 환경 | **바닐라 먼저**, SFO/AI 스택은 나중 재검증 |
| 배포 경로 | 빌드한 `.pack` → `%APPDATA%\The Creative Assembly\Warhammer3\mods\` → 런처에서 활성화 |

## 저장소 구조
```
tw3-campaign-advisor/
├─ src/script/campaign/mod/   # .pack에 들어갈 Lua (인게임 로드 경로 그대로 미러링)
├─ scripts/                   # 빌드/패킹 스크립트
├─ build/                     # 산출 .pack (gitignore)
├─ reference/vanilla_scripts/ # 추출한 바닐라 CA 스크립트 (레퍼런스, gitignore)
├─ docs/                      # 단계별 인게임 확인 절차
├─ .luarc.json               # LuaLS(sumneko) 설정 → tw_autogen 물림
└─ .gitignore
```

## 개발 원칙 (브리프에서 확정)
- **순수 Lua.** 지금은 LLM 연동 없음.
- **읽기 전용.** write-back 없음.
- **Windows 전용.**
- **전투 범위 밖** (AI General III가 담당).
- **API를 기억으로 지어내지 않는다.** tw_autogen 정의 + 추출한 바닐라 스크립트를 ground truth로.

## Phase 1 진행 (각 단계는 인게임 확인 후 다음으로)
1. [진행중] 프로젝트 뼈대 + 툴링 (git, tw_autogen LSP, RPFM 빌드)
2. [ ] 캠페인 시작 시 로드되는 스크립트 + 로드 증거 로그
3. [ ] 캠페인 UI에 커스텀 버튼 추가
4. [ ] 클릭 시 현재 상태(재정/영토 수/군대 수/인접 팩션) 덤프

## 로드맵 (지금 구현 안 함)
- Phase 2: 유틸리티 점수 추천 엔진 (CAI 테이블 시드)
- Phase 3: 외부 LLM 파일 브리지
- Phase 4: 화이트리스트 write-back + 확인 다이얼로그
