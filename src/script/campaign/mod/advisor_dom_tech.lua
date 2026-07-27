--[[===========================================================================
  TW3 어드바이저 — 연구(Technology) 탭 · v51
  ---------------------------------------------------------------------------
  이 탭만 구조가 다르다. 런타임에 기술 '목록'을 묻는 API가 아예 없기 때문이다.
    있는 것: has_technology(키) · is_currently_researching() · research_queue_idle()
             num_completed_technologies() · has_available_technologies()
    없는 것: "내 기술 트리에 무엇이 있는가"를 돌려주는 함수
  그래서 게임 DB에서 뽑은 표(advisor_db_tech.lua = CA_TECH)를 동봉하고,
  그 키를 하나씩 has_technology로 물어 '지금 고를 수 있는 것'을 찾아낸다.
  ❌ 없는 것(정직):
    - 기술의 효과. technology_effects_junction까지는 동봉하지 않았다
      → "무엇에 좋은 기술인지"는 말하지 않고, 계열(내정/군사/공학)과
        선행조건·티어까지만 말한다.
    - 연구 속도·남은 턴 수. 조회 API가 없다.
  has_technology 호출은 공짜가 아니다 → 예산(BUDGET)을 두고 초과하면 밝힌다.
  로드 순서 무보장 → CA_U/CA_TECH/CA_DOMAINS 접근은 전부 '호출 시점'에만.
=============================================================================]]

CA_DOMAINS = CA_DOMAINS or {}

local function U() return CA_U or {} end
local function say(msg) local u = U(); if u.proof then pcall(function() u.proof(msg, true) end) end end

-- 기술 한글 이름. 로컬 키 `technologies_onscreen_name_<키>`는 언어팩 실측(1,863개).
-- v54 판독에서 이 탭이 `wh3_dlc20_chs_kho_warriors_gift_slot_2` 같은 원시 키를
-- 그대로 뿌리고 있었다 — 한국어 어드바이저인데 읽을 수가 없었다.
local function tname(k) local u = U(); return (u.tech_name and u.tech_name(k)) or tostring(k) end

-- 계열은 effects.category 실측값 3종이 전부다: campaign / battle / both.
-- (technologies의 is_civil/is_military는 1869개 '전부' military인 죽은 필드라 안 쓴다.)
local CAT_KO = { c = "지도 효과", b = "전투 효과", x = "지도+전투" }
local BUDGET = 300          -- has_technology 호출 상한(턴당 1회, 탭 처음 열 때만)
local SHOW   = 6            -- 화면에 띄울 후보 수

-- 내 팩션에 맞는 노드셋 고르기: 팩션 지정 > 서브컬처 > 컬처.
-- 어느 쪽으로 잡혔는지도 돌려준다 — 틀렸을 때 프루프에서 바로 보이게.
local function pick_set(S)
	local T = CA_TECH
	if type(T) ~= "table" or type(T.sets) ~= "table" then return nil, "표 없음" end
	local fac, sub, cul = S and S.faction, S and S.subculture, S and S.culture
	local by_f, by_s, by_c = nil, nil, nil
	for k, m in pairs(T.sets) do
		if type(T.list) == "table" and T.list[k] then
			-- 팩션 지정 세트는 '그 팩션 전용'이다. 컬처가 같다고 남에게 주면 안 된다.
			--   실례: emp_wulfhart(42개)와 emp_civ_reworkd(73개)는 컬처가 같다.
			--   이걸 안 걸러서 pairs() 순회 순서에 따라 제국이 매번 다른 트리를 받았다.
			local general = (m.fac == nil)
			if fac and m.fac == fac then
				if by_f == nil or k < by_f then by_f = k end
			elseif general then
				-- 같은 등급에 여럿이면 이름 순으로 고정한다(pairs 순서는 보장되지 않는다).
				if sub and m.sub == sub and (by_s == nil or k < by_s) then by_s = k end
				if cul and m.cul == cul and (by_c == nil or k < by_c) then by_c = k end
			end
		end
	end
	if by_f then return by_f, "팩션" end
	if by_s then return by_s, "서브컬처" end
	if by_c then return by_c, "컬처" end
	return nil, "일치 없음"
end

-- ── 수집 ──────────────────────────────────────────────────────────────
local function gather(f, S)
	local G = { avail = {}, notdone = {}, done = 0, total = 0, spent = 0, budget_hit = false }
	pcall(function() G.researching = f:is_currently_researching() end)
	pcall(function() G.idle = f:research_queue_idle() end)
	pcall(function() G.done = f:num_completed_technologies() end)
	pcall(function() G.any_left = f:has_available_technologies() end)

	G.set, G.how = pick_set(S)
	if not G.set then return G end
	G.odd = (CA_TECH.sets[G.set] or {}).odd == true   -- 생성기가 표시한 '구조 불확실'

	local list = CA_TECH.list[G.set]
	G.total = #list

	-- has_technology는 같은 키를 여러 번 물을 수 있다(선행조건 확인) → 메모.
	local memo = {}
	local function owned(k)
		if memo[k] ~= nil then return memo[k] end
		if G.spent >= BUDGET then G.budget_hit = true; return nil end
		G.spent = G.spent + 1
		local v = nil
		pcall(function() v = f:has_technology(k) end)
		memo[k] = v
		return v
	end

	-- 티어 오름차순으로 이미 정렬돼 있다(생성기가 그렇게 뽑았다).
	-- 앞쪽부터 훑다가 후보가 충분히 모이면 멈춘다 — 뒤쪽 티어는 어차피 못 고른다.
	G.have = {}
	for _, e in ipairs(list) do
		if #G.avail >= SHOW * 3 or G.budget_hit then break end
		local mine = owned(e.k)
		-- 실제로 보유한 기술을 몇 개 남긴다. 원형 트리(카타이·젠취 등)에서 우리
		-- 모델이 맞는지 검증할 유일한 방법이다 — 사용자가 연구를 하나 끝내면
		-- 그게 우리가 후보로 꼽았던 것인지, 아니면 '잠겼다'고 본 것인지 드러난다.
		if mine == true and #G.have < 6 then
			G.have[#G.have + 1] = string.format("%s(t%s)", e.k, tostring(e.t))
		end
		if mine == false then
			-- 아직 안 한 기술은 따로 모아 둔다. 트리 모델이 안 맞는 진영(원형 트리)에서
			-- '고를 수 있는 것'이 0개로 나올 때, 빈 화면 대신 이걸 보여 주기 위해서다.
			if #G.notdone < SHOW * 3 then G.notdone[#G.notdone + 1] = e end
			-- odd 세트에서는 선행조건 판정을 아예 하지 않는다. 42턴 벨라코르 실측으로
			-- 확정됐다: 보유 중인 ~chariots(티어5)가 ~marauders(티어7)를, ~diplomacy(티어6)가
			-- ~chosen(티어7)을 부모로 갖는다 — 부모가 자식보다 상위 티어다. 이 트리들에선
			-- 링크 방향이 뒤집혀 있어 부모-자식으로 뽑은 후보는 틀린다. 그럴듯한 오답을
			-- 내놓느니 '아직 안 한 기술'만 확실하게 보여 준다.
			if not G.odd then
				-- 선행조건은 AND가 아닐 수 있다. DB의 required_parents가 '부모 중 몇 개'를
				-- 뜻하고(n), 없으면 전부 필요하다.
				local ready = true
				if type(e.p) == "table" and #e.p > 0 then
					local have = 0
					for _, pk in ipairs(e.p) do if owned(pk) == true then have = have + 1 end end
					ready = have >= (e.n or #e.p)
				end
				if ready then G.avail[#G.avail + 1] = e end
			end
		end
	end
	return G
end

-- 지금 상황에서 어느 계열을 먼저 올릴지. 판단 근거를 같이 돌려준다.
-- (기술의 개별 효과를 읽을 수 없으니, 말할 수 있는 건 '계열'까지다.)
-- 파생값(재정 버퍼 등)은 S가 아니라 B.D에 담긴다 — ensure_base가 그렇게 넘긴다.
local function priority(S, B)
	local D = B and B.D
	local buffer = D and D.buffer
	local known = D and D.buffer_known
	local income = S and S.income
	if (type(income) == "number" and income <= 0)
	   or (known and type(buffer) == "number" and buffer < 5) then
		return "c", "재정이 빠듯합니다 — 지도 효과(수입·성장·치안) 쪽이 먼저 값을 합니다."
	end
	local wars = 0
	if type(S and S.war_set) == "table" then for _ in pairs(S.war_set) do wars = wars + 1 end end
	local border = #((S and S.border_enemies) or {})
	if border > 0 or wars >= 2 then
		return "b", "국경에 적을 두고 있습니다 — 전투 효과(유닛 능력) 쪽이 당장 쓰입니다."
	end
	return "c", "급한 전선이 없습니다 — 지도 효과로 기반을 넓혀 둘 때입니다."
end

-- ── 본문 ─────────────────────────────────────────────────────────────
local function build(S, B)
	local f = nil
	pcall(function() f = cm:get_local_faction(true) end)
	if not f then
		say("[연구] 팩션 조회 실패")
		return { "⚠ 연구 정보를 읽지 못했습니다." }
	end

	local G = gather(f, S)
	say(string.format("[v51연구프로브] 노드셋=%s(%s) 표기술=%s 완료=%s 연구중=%s 유휴=%s 남음=%s | 후보=%s 미완료=%s 호출=%s%s",
		tostring(G.set), tostring(G.how), tostring(G.total), tostring(G.done),
		tostring(G.researching), tostring(G.idle), tostring(G.any_left),
		tostring(#G.avail), tostring(#G.notdone), tostring(G.spent),
		G.budget_hit and "(예산 소진)" or ""))
	if G.avail and #G.avail > 0 then
		local ks = {}
		for i = 1, math.min(#G.avail, 4) do ks[#ks + 1] = G.avail[i].k .. "(t" .. tostring(G.avail[i].t) .. ")" end
		say("[v52후보] " .. table.concat(ks, " ") ..
			(G.odd and "  ※구조불확실 세트 — 실제 보유분과 대조해 모델을 검증할 것" or ""))
	end
	if G.have and #G.have > 0 then
		say("[v52보유] " .. table.concat(G.have, " "))
	end

	local L = {}
	local head = {}
	if type(G.done) == "number" then head[#head + 1] = string.format("완료 %d", G.done) end
	if G.researching == true then head[#head + 1] = "연구 중"
	elseif G.researching == false then head[#head + 1] = "⚠ 연구 안 함" end
	-- "내 기술표 N개"는 뺐다 — '기술표'는 개발자 어휘고, 플레이어에게 총계는 판단 재료가 아니다.
	L[#L + 1] = "【연구】 " .. ((#head > 0) and table.concat(head, " · ") or "상태를 읽지 못했습니다")

	-- 가장 중요한 한 줄: 연구가 멈춰 있는가
	L[#L + 1] = ""
	if G.researching == false or G.idle == true then
		L[#L + 1] = "⚠ 연구가 멈춰 있습니다 — 매 턴 그냥 버려지는 자원입니다. 지금 하나 고르세요."
	elseif G.researching == true then
		L[#L + 1] = "연구는 돌아가고 있습니다. 끝나면 아래에서 다음 것을 고르세요."
	end

	if not G.set then
		say(string.format("[연구] 노드셋 미일치(%s) — 팩션·서브컬처·컬처 전부 불일치(모드/신규 진영?)", tostring(G.how)))
		L[#L + 1] = ""
		L[#L + 1] = "─ 이 진영의 연구 추천은 지원하지 않습니다."
		return L
	end

	local cat, why = priority(S, B)
	-- 우선 계열 먼저, 그 다음 티어 낮은 순(싼 것부터).
	local function rank_by(cat_, arr)
		local ord = {}
		for i, e in ipairs(arr) do ord[e] = i end        -- 원래 순서(=티어순) 보존용
		table.sort(arr, function(a, b)
			local pa = (a.c == cat_) and 0 or 1
			local pb = (b.c == cat_) and 0 or 1
			if pa ~= pb then return pa < pb end
			if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) < (b.t or 0) end
			return (ord[a] or 0) < (ord[b] or 0)
		end)
	end
	local function list_out(arr)
		-- 목록은 권하는 계열을 앞으로 정렬한다. 그래서 상위 SHOW개가 전부 그 계열이면
		-- "◀ 지금 권하는 계열"이 전부에 붙어 구분 정보가 0이 된다(42턴 실측: 6개 전부).
		-- 섞여 있을 때만 표시해서 마커가 실제로 뭔가를 가리키게 한다.
		local mixed = false
		for i = 1, math.min(#arr, SHOW) do
			if (arr[i].c == cat) ~= (arr[1].c == cat) then mixed = true; break end
		end
		for i = 1, math.min(#arr, SHOW) do
			local e = arr[i]
			L[#L + 1] = string.format("%d. %s", i, tname(e.k))
			L[#L + 1] = string.format("   티어 %s · %s 계열%s", tostring(e.t or "?"),
				CAT_KO[e.c] or "기타", (mixed and e.c == cat) and " ◀ 지금 권하는 계열" or "")
		end
		if #arr > SHOW then L[#L + 1] = string.format("  … 외 %d개", #arr - SHOW) end
		L[#L + 1] = ""
		L[#L + 1] = "─ 무엇부터"
		L[#L + 1] = "  " .. why
		-- 권하는 계열이 목록에 하나도 없으면 그렇게 말한다. v51 눈검증에서
		-- "지도 효과 쪽이 먼저"라고 해 놓고 목록은 전부 전투 효과인 경우가 나왔다.
		local any = false
		for _, e in ipairs(arr) do if e.c == cat then any = true; break end end
		if not any then
			L[#L + 1] = string.format("  다만 지금 고를 수 있는 것 중엔 %s 기술이 없습니다 — %s부터 가야 합니다.",
				CAT_KO[cat] or "그 계열", CAT_KO[arr[1] and arr[1].c] or "있는 것")
		end
	end

	if #G.avail > 0 then
		rank_by(cat, G.avail)
		L[#L + 1] = ""
		if G.odd then
			-- odd 세트(원형 트리 — 링크 방향 역전 실측, v53)는 선행조건에 확신이 없다.
			-- 그 진단은 프루프([v52후보]의 표시)에 있고, 화면엔 사용자에게 필요한
			-- 한 가지만 남긴다: 잠긴 게 섞여 있을 수 있다는 사실.
			L[#L + 1] = "─ 다음 연구 후보"
			L[#L + 1] = "  (일부는 아직 잠겨 있을 수 있습니다)"
		else
			L[#L + 1] = "─ 지금 고를 수 있는 기술"
		end
		list_out(G.avail)
	elseif G.any_left == false then
		L[#L + 1] = ""
		L[#L + 1] = "─ 더 연구할 것이 없습니다. 기술 트리를 다 올렸습니다."
	elseif #G.notdone > 0 then
		-- 후보 0인데 잔여 있음 = 트리 모델이 이 진영과 안 맞는 것(odd 세트가 대표).
		-- 원인 진단은 프루프로, 화면엔 남은 기술 목록 + 잠김 주의 한 줄만.
		say(G.odd and "[연구] odd 세트 — 선행조건 판정 보류(링크 방향 역전, v53 실측)"
		          or "[연구] 표-실제 불일치 — 후보 0인데 미완료 잔존")
		rank_by(cat, G.notdone)
		L[#L + 1] = ""
		L[#L + 1] = "─ 아직 연구하지 않은 기술"
		L[#L + 1] = "  (일부는 아직 잠겨 있을 수 있습니다)"
		list_out(G.notdone)
	else
		say("[연구] 후보·미완료 모두 0인데 any_left ~= false — 표와 실제 불일치")
		L[#L + 1] = ""
		L[#L + 1] = "─ 남은 연구를 찾지 못했습니다."
	end
	if G.budget_hit then
		say(string.format("[연구] has_technology 예산 %d회 소진 — 뒤쪽 기술 미확인", BUDGET))
		L[#L + 1] = "  (기술이 많아 앞쪽 위주로 확인했습니다)"
	end
	-- "개별 효과 수치는 읽지 않았다"류 한계 설명은 화면에서 뺐다(개발자 메타 발언).
	return L
end

CA_DOMAINS[#CA_DOMAINS + 1] = { id = "tech", order = 40, title = "연구", build = build }

-- 오프라인 하니스용 노출(인게임에선 전역이 nil이라 no-op)
if ADVISOR_TEST_EXPORTS then
	CA_TEST_TECH = { build = build, gather = gather, pick_set = pick_set,
	                 priority = priority, BUDGET = BUDGET, SHOW = SHOW, tname = tname }
end
