# WH3 전략 API 카탈로그 — 디컴파일 체계 감사 결과 (2026-07-24)

3개 병렬 에이전트가 `reference/vanilla_scripts`(833개 CA 스크립트)를 목표 지향으로 전수 감사.
**전부 바닐라 실사용 근거(file:line) 있는 것만** 수록. 어드바이저 전략 2.0(계획 엔진)의 재료.

## 1. 승리조건 / 캠페인 목표
| API | 반환 | 근거 |
|---|---|---|
| `victory_objectives_ie` 전역 테이블 | 진영별 승리목표 정의(alignment→objectives/conditions/payload_bundle) | victory_objectives.lua:2-71,241,815 |
| `victory_objectives_ie.subcultures[sub].alignment` | order/destruction/death/chaos | :241-243 |
| `faction:has_effect_bundle("wh3_main_ie_victory_objective_<align>_<short|long>")` | 승리 완료 여부(번들 보유) | 번들 지급 :4267-4282 |
| `cm:get_saved_value("<lord>_short_victory_count")` | 일부 LL 전용 진행 카운터 | :4646,4815,4871 |
| `faction:active_missions(type_str, bool):num_items()` | 활성 미션 수(타입별) | wh3_campaign_ogre_contracts.lua:60 |
| ❌ 없음 | `model():victory_conditions()` 류 getter, 전역 미션 레지스트리 | 전수 검색 0건 |

## 2. 엔드게임 위기 (실시간 경보 가능!)
| API | 의미 | 근거 |
|---|---|---|
| `cm:get_saved_value("endgame_scenario_data")` | `{scenario, turn}` = **위기 무장됨 + 발동 턴** | endgames.lua:143,238-242,267 |
| `cm:get_saved_value("endgame_ultimate_crisis_data")` | 얼티밋 위기 `{turn_trigger, pending_mission,…}` | :147,317 |
| `cm:get_saved_value("endgame_<시나리오>_saved_data")` 존재 | 해당 위기 **이미 발동·활성** | endgame_pyramid_of_nagash.lua:180 |
| `endgame.triggered` / `endgame.settings` 전역 | 발동 여부 / 설정 | endgames.lua:14,159-201 |
| `cm:model():shared_states_manager():get_state_as_float_value("endgame_turn_trigger_range_min"/"_max")` | 설정된 발동 턴 윈도우 | :180-182 |

## 3. 속주 완성 / 건물
| API | 반환 | 근거 |
|---|---|---|
| `cm:num_regions_controlled_in_province_by_faction(province, faction)` | **(보유수, 전체수)** — 2/4 계산 완제품 | lib_campaign_manager.lua:8432-8442 |
| `region:province()` → `province:regions()` | 속주의 전 지역 리스트 | :8464,8470 / building_logging.lua:38-44 |
| `slot:building():building_level()` | 건물 티어(0-base) | :8662, wh2_campaign_confederation_missions.lua:453 |
| `region:settlement():primary_slot()/port_slot()/active_secondary_slots()` | 슬롯 접근 | wh2_campaign_custom_starts.lua:521-594 |
| `garrison_residence:has_army()→:army()` | 수비대 military_force(→strength) | lib_campaign_manager.lua:3430-3437 |
| ❌ 없음 | 지역 성장(growth)·지역/속주 단위 수입 | 전수 검색 0건 |
| ※ CA 자체 넛지 | `one_settlement_from_completing_province` 쿼리 존재 = CA도 속주완성 조언함 | wh3_narrative_query_templates.lua:513,578 |

## 4. 부대 구성 (배틀 아님, 캠페인 읽기)
| API | 반환 | 근거 |
|---|---|---|
| `mf:unit_list():item_at(i):unit_key()` | 정확한 유닛 DB 키 | lib_campaign_invasion_manager.lua:126-127 |
| `unit:unit_class()` | 광역 클래스(예: art_fld=야포, com=지휘) | wh_dlc07_virtues_and_traits.lua:89 |
| `unit:unit_category()` | 세분 카테고리 | lib_campaign_manager.lua:5729,5766 |
| `cm:proportion_of_unit_class_in_military_force(mf, class)` | 클래스 비율 헬퍼 | :9122-9148 |
| `unit:percentage_proportion_of_full_strength()` | 유닛 충원율 | :9061,9242 |
| `cm:force_gold_value(mf)` / `mf:strength()` | 부대 가치/강도 | :9223-9247 / 다수 |

## 5. 국력·전투·경제
| API | 반환 | 근거 |
|---|---|---|
| `cm:model():world():faction_strength_rank(faction)` | **공식 국력 순위(1=최강)** | wh2_dlc12_kroak.lua:116-124, wh3_main_legendary_characters.lua:1938 |
| `cm:cai_evaluate_quick_deal_action(f, other, "diplomatic_option_*")` | score, can_issue — **CA 자체 임계 score > -3** | wh3_narrative_shared_chains.lua:2744,2911 |
| `cm:pending_battle_cache_attacker_value()/_defender_value()` | 직전/현재 전투 양측 골드가치 | lib_campaign_manager.lua:11929-11945 |
| `faction:expenditure()/upkeep()/trade_value()` | 지출/유지비/교역 상세 | debug_economy_logging.lua:28-37 |
| `faction:is_allowed_to_capture_territory()` | 호드 여부(정착 가능) | wh3_narrative_query_templates.lua:1032-1036 |
| `cm:get_regions_adjacent_to_faction(faction)` | 인접 지역 리스트 헬퍼 | :1395-1403 |
| ❌ 없음 | 스킬포인트 잔여 수치, 위험예측(danger) API, cai 전략스탠스 getter | 전수 검색 0건 |

## CA 자체 조언 휴리스틱 (narrative_queries — 우리 두뇌와 비교 참고)
- 경제 조언 게이트 = `net_income() > N` (query_templates:956)
- 위협 조언 = 적 기동군이 정착지보다 가까울 때 (:439-462)
- 외교 조언 = **AI가 수락할 딜만**(score > -3) — 우리 모듈4와 동일 설계를 CA도 씀 (:2903-2921)
- 확장 조언 = 속주 1개 남았을 때·N속주 달성 (:513,633)
- 중복 방지 = advice_history 체크 (:231,344)

## 오프라인 테스트 하니스 (Debug 2.0)
- LuaJIT(=Lua 5.1) 설치: `C:\Users\veria\AppData\Local\Programs\LuaJIT\bin\luajit.exe`
- 실행: `scripts\test.ps1` 또는 `luajit test\run_brain_tests.lua "<repo루트>"`
- mod 끝의 `ADVISOR_TEST_EXPORTS` 게이트로 순수 함수 노출(게임에선 no-op)
- 커버: 조사/국면 우선순위/신규 모듈 산문/추세·히스토리/자원 파이프라인/**24프로필×전군주 무결성**/nil폭풍
- 한계(정직): **API 경계(게임 안 실제 값)는 여기서 못 잡음** — 그건 인게임 1회 확인용
