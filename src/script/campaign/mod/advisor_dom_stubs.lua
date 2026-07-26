--[[===========================================================================
  TW3 어드바이저 — 미구현 탭 자리표시 · v41
  ---------------------------------------------------------------------------
  탭은 지금 만들어 두되, 내용이 없는 칸을 "문제 없음"처럼 보이게 두지 않는다.
  각 탭은 (1) 아직 비었다는 사실, (2) 무엇을 보여줄 예정인지, (3) 그 근거가
  될 실측 API를 밝힌다. 도메인이 완성되면 이 파일에서 해당 항목만 지운다.
  ※ 이 파일의 항목은 order를 각 도메인 파일과 동일하게 유지해야 자리가 안 밀린다.
=============================================================================]]

CA_DOMAINS = CA_DOMAINS or {}

local PENDING = {
	{ id = "diplo", order = 30, title = "외교", eta = "다음 차례",
	  plan = { "누구와 무엇을 맺을 수 있는지 — AI가 실제로 수락할 딜만 추려서",
	           "태도·관계 수치, 동맹/교역/불가침 현황, 남은 교역로 여유",
	           "선전포고가 임박한 이웃(CAI 스탠스 감시)" },
	  api  = "diplomatic_attitude_towards · cai_evaluate_quick_deal_action · unused_international_trade_route" },
	{ id = "tech", order = 40, title = "연구", eta = "5순위(마지막)",
	  plan = { "지금 무엇을 연구할지, 우선순위와 이유" },
	  api  = "has_technology·is_currently_researching만 존재 — 기술 목록 API가 없어 DB 추출이 선행돼야 합니다" },
	{ id = "war", order = 60, title = "전쟁", eta = "4순위",
	  plan = { "전선별 전력비와 승산, 어디를 먼저 칠지",
	           "포위·접근 중인 적군, 강화가 필요한 지점",
	           "휴전이 통할 상대" },
	  api  = "force_gold_value·mf:strength·garrison_residence:is_under_siege·cai_evaluate_quick_deal_action" },
	{ id = "agent", order = 70, title = "기타", eta = "미정",
	  plan = { "요원·첩보 — 종류별 정원 여유, 적 가시 캐릭터, 배치 제안" },
	  api  = "agent_cap_remaining·agent_subtype_cap_remaining·get_foreign_visible_characters_for_player" },
}

for _, p in ipairs(PENDING) do
	CA_DOMAINS[#CA_DOMAINS + 1] = {
		id = p.id, order = p.order, title = p.title,
		build = function()
			local L = { string.format("【%s】 아직 만들지 않았습니다 (%s).", p.title, p.eta), "" }
			L[#L + 1] = "─ 여기에 들어갈 것"
			for _, s in ipairs(p.plan) do L[#L + 1] = "• " .. s end
			L[#L + 1] = ""
			L[#L + 1] = "─ 근거로 쓸 실측 API"
			L[#L + 1] = "  " .. p.api
			return L
		end,
	}
end
