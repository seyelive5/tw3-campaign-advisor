# CAI 시드 데이터 — cai_personalities_budget_allocations (실측 추출)

Phase 2 스코어링 엔진의 시드 가중치 출처. **CA의 AI가 실제로 쓰는 예산 배분값**을
db.pack에서 추출·검증한 것(기억/짐작 아님).

## 출처 & 재현 방법
- 테이블: `db\cai_personalities_budget_allocations_tables\data__` (db.pack 내부, zstd 압축)
- 스키마: `%APPDATA%\FrodoWazEre\rpfm\config\schemas\schema_wh3.ron` → 이 테이블 **version 3, 38컬럼**
- 바이너리 포맷(실측):
  - 헤더: `FD FE FC FF`+u16len+UTF16(GUID) → `FC FD FE FF`+i32(version=3) → 1바이트 마커 → i32(행수=22) → 행 데이터(byte 91~)
  - 컬럼 순서 = **RON 필드배열 순서**(=CA 원본순), **ca_order 아님**. StringU8 = u16 길이 + UTF-8.
  - 문자열 컬럼은 바이너리 인덱스 16(key), 21(min_tax), 22(max_tax); 나머지 35개 I32.
- 검증: 파싱 후 최종 pos가 정확히 4544/4544(테이블 끝) 일치 + funds% 합계≈100.
- 도구: zstd `C:\Users\veria\tools\zstd\zstd-v1.5.7-win64\zstd.exe`, 팩 인덱스 파서는 build.ps1 Read-Pack.

## 초기 자금 배분 % (funds_allocation_percentage)
7개 카테고리 합계 = 100(예외 몇 개 표기). **육군·건설이 지배적**, 기술/외교/캐릭터/해군은 funds에서 거의 0.

| personality (wh3_budget_allocation_*) | army | navy | agents | construction | diplomacy | tech | character | 합 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rogue | 80 | 0 | 3 | 15 | 2 | 0 | 0 | 100 |
| dechala | 70 | 0 | 4 | 25 | 1 | 0 | 0 | 100 |
| chaos | 65 | 0 | 3 | 30 | 2 | 0 | 0 | 100 |
| chaos_dwarfs | 65 | 0 | 3 | 30 | 2 | 0 | 0 | 100 |
| militaristic | 60 | 0 | 3 | 35 | 2 | 0 | 0 | 100 |
| **default** | **55** | 0 | 3 | **40** | 2 | 0 | 0 | 100 |
| militaristic_naval | 50 | 10 | 3 | 35 | 2 | 0 | 0 | 100 |
| builder | 50 | 0 | 3 | 45 | 2 | 0 | 0 | 100 |
| beastmen | 40 | 0 | 3 | 55 | 2 | 0 | 0 | 100 |
| wh3_prologue_active | 50 | 0 | 5 | 45 | 0 | 0 | 0 | 100 |
| wh3_prologue_passive | 25 | 0 | 0 | 25 | 0 | 0 | 0 | 50 |
| tombking | 1 | 0 | 3 | 95 | 2 | 0 | 0 | 101 |
| wh3_only_agent | 0 | 0 | 100 | 0 | 0 | 0 | 0 | 100 |
| pooled_resource_* (자원특화 12종) | 종족 특수 자원 풀 배분(대개 construction 위주). 일반 추천엔 부적합 | | | | | | | |

## 설계 함의
- **근본 축 = 군사(army) ↔ 경제(construction).** `default` 55/40 을 **중립 기준선 가중치**로 사용.
- 위협/전쟁 상황 → army 쪽으로 이동(rogue/chaos 스펙트럼), 안전/성장기 → construction 쪽(builder/beastmen).
- funds에서 tech/diplomacy/character가 0인 것은 "안 중요"가 아니라 **다른 예산경로**(upkeep 컬럼/무료)로 처리됨을 의미 → 추천에서 이들은 별도 규칙으로 다룰 것.
- 런타임에 팩션→개성 매핑은 불가(읽기전용). 그래서 이 표는 **문화/상황 기반으로 우리가 아키타입을 선택**해 시드하는 참고값으로 사용.

## 다음(미추출, 필요시)
- `cai_personalities_income_allocations` — 수입(턴별) 배분(예산 풀 배분과 별개).
- `campaign_ai_technology_path_junctions` — 종족/개성별 기술 연구 우선순위.
