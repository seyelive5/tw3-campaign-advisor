--[[===========================================================================
  TW3 어드바이저 — 진영 전략 지식베이스 (v9a)
  ---------------------------------------------------------------------------
  출처: docs/faction_profiles_research.md (병렬 에이전트 웹검증, WH3 IE 패치 8.1.x/2026).
  전역 테이블로 노출 → campaign_advisor.lua(first tick)가 읽음.
  loader가 파일명 동일 전역함수(za_faction_profiles)를 찾지만 없으면 no-op(top-level만 실행).

  pr = 두뇌 6차원 재가중(0.0~1.0): military/economy/diplomacy/expansion/tech/defense.
  런타임 식별: faction:subculture() → 이 표의 키.
  ⚠ VC·스케이븐은 9.0(2026여름) 리워크 임박 → 출시 후 갱신 요망.
=============================================================================]]

CA_FACTION_PROFILES = {
  -- ── Order ──
  ["wh_main_sc_emp_empire"] = { race="제국", identity="선제후를 외교·연합으로 통합, 초반 방어→후반 강국",
    pr={military=0.8,economy=0.7,diplomacy=0.9,expansion=0.6,tech=0.8,defense=0.75},
    tips={"선제후를 살려두고 연합해 제국 권위를 유지하세요","총기+포병+마도사 제병협동으로, 근처 위협은 초반에 제거"} },
  ["wh_main_sc_brt_bretonnia"] = { race="브레토니아", identity="농민 방벽+기사 기병 망치. 명예 전투로 기사도 성장",
    pr={military=0.95,economy=0.45,diplomacy=0.5,expansion=0.75,tech=0.45,defense=0.5},
    tips={"기병 중심 편성, 농민은 값싼 스크린으로만","열세 전투로 기사도를 파밍하고 서약을 완수하세요"} },
  ["wh3_main_sc_ksl_kislev"] = { race="키슬레프", identity="카오스 맞선 북방 방벽. 코사르+곰+얼음마법",
    pr={military=0.8,economy=0.55,diplomacy=0.6,expansion=0.55,tech=0.65,defense=0.85},
    tips={"카오스를 사냥해 헌신을 모아 신 기원 의식에 투자","궁정 vs 정교 한 진영을 정해 상대를 흡수하세요"} },
  ["wh3_main_sc_cth_cathay"] = { race="카타이", identity="원거리 총진+용군주+포병 방어형. 조화·교역 제국",
    pr={military=0.7,economy=0.85,diplomacy=0.6,expansion=0.5,tech=0.8,defense=0.95},
    tips={"음/양 조화 균형을 상시 관리하세요","대보루 관문을 수비대로 지키고 캐러밴으로 경제를 굴리세요"} },

  -- ── Order (엘프/드워프/도마뱀) ──
  ["wh_main_sc_dwf_dwarfs"] = { race="드워프", identity="느리지만 무너지지 않는 방어형. 원한·룬·사격라인",
    pr={military=0.8,economy=0.6,diplomacy=0.5,expansion=0.6,tech=0.8,defense=0.9},
    tips={"값싼 원한부터 갚아 버프를 눈덩이처럼 굴리세요","석궁+화포+철갑보병 사격라인으로 방어전을 유도"} },
  ["wh2_main_sc_hef_high_elves"] = { race="하이 엘프", identity="정예+정치력. 영향력·후원으로 전쟁 조율·규합(7.0)",
    pr={military=0.7,economy=0.7,diplomacy=0.9,expansion=0.6,tech=0.6,defense=0.7},
    tips={"영향력으로 후원 좌석을 선점하고 하이엘프를 규합","영향력 외교로 적끼리 싸우게 하고 정예는 아끼세요"} },
  ["wh_dlc05_sc_wef_wood_elves"] = { race="우드 엘프", identity="정예 궁병·기동 게릴라. 앰버·숲치유·월드루트",
    pr={military=0.8,economy=0.4,diplomacy=0.4,expansion=0.5,tech=0.6,defense=0.7},
    tips={"궁병 카이팅·집중사격, 앰버를 계획적으로 확보","월드루트로 다전선을 소방하고 아텔 로렌 방어 최우선"} },
  ["wh2_main_sc_lzd_lizardmen"] = { race="리자드맨", identity="공룡·괴수+슬란 마법 만능강군. 지오맨틱 웹·리테",
    pr={military=0.9,economy=0.6,diplomacy=0.5,expansion=0.7,tech=0.6,defense=0.7},
    tips={"공룡+사우루스 라인으로 정면 압박, 광폭화 관리","지오맨틱 웹 연결·리테 쿨다운을 상시 활용하세요"} },

  -- ── Destruction ──
  ["wh_main_sc_grn_greenskins"] = { race="그린스킨", identity="싸워야 강해지는 공격형. WAAAGH!·스크랩 스노우볼",
    pr={military=0.9,economy=0.5,diplomacy=0.35,expansion=0.85,tech=0.5,defense=0.45},
    tips={"군대를 계속 전투에 굴려 WAAAGH!를 유지하세요","이웃 그린스킨을 잡아 빠르게 확장·통합"} },
  ["wh_dlc03_sc_bst_beastmen"] = { race="비스트맨", identity="정착지 부수는 유목 히트앤런. 허드스톤·드레드",
    pr={military=0.9,economy=0.35,diplomacy=0.1,expansion=0.5,tech=0.4,defense=0.3},
    tips={"인구밀집지에 허드스톤을 심고 몰살로 Ruination 극대화","한 곳 고집 말고 계속 이동하며 새 표적을 사냥하세요"} },
  ["wh_main_sc_chs_chaos"] = { race="카오스 전사", identity="정복형. 다크 포트리스로 식민·확장+카오스 선물",
    pr={military=0.9,economy=0.5,diplomacy=0.3,expansion=0.85,tech=0.55,defense=0.55},
    tips={"다크 포트리스 지역을 확보해 경제 기반을 마련","영혼을 관리하며 선물·표식으로 군대 질을 강화"} },
  ["wh_dlc08_sc_nor_norsca"] = { race="노스카", identity="약탈 침략자. 4대신 제단+전리품 경제(7.0)",
    pr={military=0.85,economy=0.5,diplomacy=0.3,expansion=0.6,tech=0.4,defense=0.4},
    tips={"제단을 요지에 세워 4대신을 병행 축적하세요","부유한 해안을 지속 약탈하되 보급 캐러밴을 호위"} },
  ["wh3_main_sc_ogr_ogre_kingdoms"] = { race="오거 킹덤", identity="고기로 굴러가는 용병형. 캠프·계약 반유목",
    pr={military=0.85,economy=0.5,diplomacy=0.5,expansion=0.6,tech=0.45,defense=0.5},
    tips={"전진 축선에 캠프를 세워 고기 보급선을 확보","계약을 적극 수락해 현금·고기·부관을 수급하세요"} },

  -- ── Chaos Daemons ──
  ["wh3_main_sc_kho_khorne"] = { race="코른", identity="순수 학살. 외교·경제 포기, 멈추면 약해짐",
    pr={military=1.0,economy=0.3,diplomacy=0.1,expansion=0.85,tech=0.4,defense=0.2},
    tips={"1턴부터 쉼 없이 교전해 해골을 수급하세요","해골왕좌 티어를 올려 블러드호스트로 다전선 압박"} },
  ["wh3_main_sc_nur_nurgle"] = { race="너글", identity="내구·역병·소모전. 부패로 갉아먹는 스노우볼",
    pr={military=0.8,economy=0.55,diplomacy=0.3,expansion=0.6,tech=0.7,defense=0.8},
    tips={"컬티스트로 감염 거점을 넓혀 역병 자원을 흑자화","내구로 소모전을 걸되 급하게 밀지 마세요"} },
  ["wh3_main_sc_tze_tzeentch"] = { race="젠취", identity="마법·기만. 그리모어 술책·변화의 격변·순간이동",
    pr={military=0.6,economy=0.6,diplomacy=0.7,expansion=0.55,tech=0.95,defense=0.5},
    tips={"그리모어를 모아 기술 트리를 밀어붙이세요","변화의 격변으로 대리전을 유발하고 무혈 확장"} },
  ["wh3_main_sc_sla_slaanesh"] = { race="슬라네쉬", identity="속도·유혹. 최고 기동 치고빠지기+속국화",
    pr={military=0.8,economy=0.55,diplomacy=0.85,expansion=0.7,tech=0.45,defense=0.3},
    tips={"기동력으로 각개격파, 정면 난타전은 피하세요","선물→유혹 영향력으로 인간·엘프를 속국화하세요"} },
  ["wh3_main_sc_dae_daemons"] = { race="카오스 데몬", identity="4대신 자유 조합 만능. 데몬프린스 커스텀·영광",
    pr={military=0.9,economy=0.4,diplomacy=0.2,expansion=0.8,tech=0.55,defense=0.4},
    tips={"초반엔 1~2개 신 트랙에 집중해 핵심을 먼저 해금","데몬 프린스는 역할 확정 후 방어를 보강하세요"} },
  ["wh3_dlc23_sc_chd_chaos_dwarfs"] = { race="카오스 드워프", identity="산업·경제 지배. 노동력·헬포지, 느린 시작 최상위 후반",
    pr={military=0.85,economy=1.0,diplomacy=0.45,expansion=0.7,tech=0.9,defense=0.75},
    tips={"초반 노동력 극대화가 최우선입니다","자르 탑 좌석을 선점하고 호송대로 자원을 교역"} },

  -- ── Death / Skaven ──
  ["wh_main_sc_vmp_vampire_counts"] = { race="뱀파이어 카운트", identity="마법+붕괴없는 언데드 소모전. 사자 소환 공짜 보충",
    pr={military=0.85,economy=0.45,diplomacy=0.2,expansion=0.8,tech=0.5,defense=0.6},
    tips={"영웅으로 부패를 선행한 뒤 진격하세요","군주를 절대 잃지 마세요(사망 시 전군 붕괴)"} },
  ["wh2_dlc09_sc_tmb_tomb_kings"] = { race="툼 킹", identity="무료 군대+부대 상한. 인프라·상한 키워 후반 전환",
    pr={military=0.8,economy=0.55,diplomacy=0.3,expansion=0.65,tech=0.7,defense=0.7},
    tips={"초반엔 건물로 부대 상한과 카노픽 수입을 확보","남는 골드는 시신 안치소(아이템·전설군단)에 투자"} },
  ["wh2_dlc11_sc_cst_vampire_coast"] = { race="뱀파이어 코스트", identity="해적 은신처 경제+화약포병 '건볼' 화력",
    pr={military=0.8,economy=0.75,diplomacy=0.3,expansion=0.55,tech=0.65,defense=0.55},
    tips={"고수익 항구를 은신처(Cove)로 도배해 수동수입 구축","네크로펙스+포병 건볼 조합, 근접 노출은 피하세요"} },
  ["wh2_main_sc_def_dark_elves"] = { race="다크 엘프", identity="노예로 경제·건설, 살육의 기세로 폭발. 초공격형",
    pr={military=0.85,economy=0.75,diplomacy=0.35,expansion=0.85,tech=0.55,defense=0.55},
    tips={"쉼 없이 전쟁·약탈로 노예를 사냥하세요","노예는 즉시 건설·수입에 소비해 control을 관리"} },
  ["wh2_main_sc_skv_skaven"] = { race="스케이븐", identity="소모물량 탱킹+무기팀·포병. 언더엠파이어·식량",
    pr={military=0.85,economy=0.7,diplomacy=0.2,expansion=0.85,tech=0.7,defense=0.55},
    tips={"식량을 항상 안전권으로 유지하며 확장하세요","언더엠파이어를 적진 깊이 심고 물량+화력으로 학살"} },
}

-- 프로필 없을 때 기본값(범용 균형)
CA_FACTION_DEFAULT = { race="(일반)", identity="",
  pr={military=0.7,economy=0.6,diplomacy=0.5,expansion=0.6,tech=0.6,defense=0.6}, tips={} }
