# PFH5 pack 포맷 (WH3 8.1.1, 실측 도출)

RPFM v4/v5는 더 이상 `rpfm_cli`를 배포하지 않고, 시스템에 실사용 가능한 CLI 패커가 없다.
그래서 `scripts/build.ps1`이 **의존성 0**으로 직접 PFH5 pack을 만든다.
포맷은 추측이 아니라 **디스크의 실제 pack을 해부**해 도출했고, 참조 pack 재패킹→
**바이트 단위 일치**(`build.ps1 -SelfTest`)로 검증했다.

## 헤더 (28 bytes, little-endian)
| offset | size | 필드 | 값(예) |
|---|---|---|---|
| 0  | 4 | magic | `PFH5` |
| 4  | 4 | 비트마스크/타입 | `0x03`=Mod, `0x01`=Release. 하위니블=타입, 상위=플래그 |
| 8  | 4 | 의존성(부모 pack) 개수 | 0 |
| 12 | 4 | 의존성 블록 크기(byte) | 0 |
| 16 | 4 | 파일 수 | N |
| 20 | 4 | 파일 인덱스 크기(byte) | |
| 24 | 4 | 타임스탬프(unix) | 0 가능 |

## 파일 인덱스 (헤더 다음, 의존성 블록 이후)
엔트리 반복(파일 수만큼):
- `4B` 파일 크기(u32)
- `1B` 압축 플래그 — **0=비압축, 1=zstd 압축**
- `NB` 경로 문자열 (백슬래시 `\` 구분, **null 종료**)

## 파일 데이터
인덱스 순서대로 각 파일 바이트를 연속 저장.
검증식: `28 + 의존성블록 + 인덱스 + Σ(파일크기) = 파일 전체 크기`.

## 압축 (바닐라 data_script.pack 등, flag=1)
`4B 압축해제크기(u32 LE)` + `zstd 프레임(매직 28 B5 2F FD)`.
- 우리 모드 pack은 **비압축(flag 0)** 으로 쓴다 — 게임은 비압축 파일을 정상 로드한다(수많은 모드가 그러함).
- 바닐라 스크립트를 레퍼런스로 **읽으려면** zstd 디코더가 필요(현재 미구현, Phase 1 불필요).

## 모드 스크립트 자동 로드 (실측 확인)
- 로더: `script\_lib\lib_mod_loader.lua` (data_script.pack 내, zstd 압축)
- 로드 폴더: `script\campaign\mod\*.lua` — 바닐라 8.1.1도 여기에 7개 파일
  (`battle_logging.lua`, `building_logging.lua`, `show_realms_of_chaos.lua`,
  `waaagh_logging.lua` 등)을 넣어 캠페인 시작 시 자동 실행한다.
- 파일명 자유(glob) → 별도 등록 불필요. 우리는 `campaign_advisor.lua` 사용.
