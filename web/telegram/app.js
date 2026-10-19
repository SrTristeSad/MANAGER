(() => {
  "use strict";
  const app = window.Telegram?.WebApp;
  const $ = (id) => document.getElementById(id);
  const tabs = [...document.querySelectorAll(".tab[data-view]")];
  const views = {
    clients: { title: "Clientes", kicker: "CADASTRO / IDENTIDADES", subtitle: "Identidades que você tem permissão para consultar." },
    sessions: { title: "Sessões", kicker: "CONEXÕES / ATIVIDADE", subtitle: "Conexões e sessões dentro da sua área de acesso." },
    products: { title: "Produtos", kicker: "CATÁLOGO / PLANOS", subtitle: "Planos autorizados para sua identidade." },
    quotas: { title: "Cotas", kicker: "TRÁFEGO / FRANQUIAS", subtitle: "Franquias e consumo dos clientes autorizados." },
  };
  const state = { view: "clients", page: 0, limit: 8, rows: [], hasMore: false, loading: false, token: 0, controller: null };
  const number = new Intl.NumberFormat("pt-BR");
  const text = (value, fallback = "—") => (typeof value === "string" || typeof value === "number") && String(value).length ? String(value) : fallback;
  const integer = (value) => typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0;
  const bytes = (value) => {
    const n = integer(value);
    if (!n) return "0 B";
    const units = ["B", "KB", "MB", "GB", "TB"];
    const i = Math.min(Math.floor(Math.log(n) / Math.log(1024)), units.length - 1);
    return new Intl.NumberFormat("pt-BR", { maximumFractionDigits: i ? 1 : 0 }).format(n / 1024 ** i) + " " + units[i];
  };
  const el = (tag, className, textValue) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (textValue !== undefined) node.textContent = textValue;
    return node;
  };
  const showNotice = (message) => {
    $("notice").hidden = !message;
    $("notice").textContent = message || "";
  };
  const status = (type, label) => {
    $("connectionStatus").className = "status" + (type ? " " + type : "");
    $("connectionText").textContent = label;
  };
  const info = (row) => {
    if (state.view === "clients") {
      const stateName = { active: "Ativo", disabled: "Desativado", expired: "Expirado" }[row.state] || text(row.state, "Indefinido");
      return { name: text(row.identity_id), sub: "Responsável: " + text(row.owner, "Sem proprietário") + " · Plano: " + text(row.product_id),
        tag: stateName, off: row.state !== "active", detail: "Até " + number.format(integer(row.max_sessions)) + " sessões", initial: text(row.identity_id)[0] };
    }
    if (state.view === "sessions") {
      return { name: text(row.identity_id), sub: "Sessão " + text(row.session_id) + " · " + text(row.node_id, "Nó local"),
        tag: text(row.protocol, "—").toUpperCase(), off: false,
        detail: "Restam " + number.format(integer(row.remaining_seconds)) + " s", initial: "↗" };
    }
    if (state.view === "products") {
      return { name: text(row.name, text(row.product_id)), sub: "ID: " + text(row.product_id) + " · " + number.format(integer(row.max_sessions)) + " sessões",
        tag: row.enabled === 1 ? "Ativo" : "Inativo", off: row.enabled !== 1, detail: "Franquia: " + bytes(row.traffic_quota_bytes), initial: "P" };
    }
    const used = integer(row.used_bytes);
    const quota = integer(row.quota_bytes);
    return { name: text(row.identity_id), sub: "Produto: " + text(row.product_id) + " · " + text(row.period, "Ciclo atual"),
      tag: row.exceeded === 1 ? "Limite excedido" : "Em uso", off: row.exceeded === 1,
      detail: bytes(used) + " / " + (quota ? bytes(quota) : "sem limite"),
      progress: quota ? Math.min(100, Math.round(used / quota * 100)) : null, initial: "%" };
  };
  const draw = () => {
    const records = $("records");
    records.replaceChildren();
    const filter = $("searchInput").value.toLocaleLowerCase("pt-BR").trim();
    const visible = state.rows.filter((row) => !filter || Object.values(row).some((value) =>
      (typeof value === "string" || typeof value === "number") && String(value).toLocaleLowerCase("pt-BR").includes(filter)));
    if (!visible.length) {
      const empty = el("div", "empty");
      const symbol = el("div", "", "◇");
      symbol.style.fontSize = "32px";
      empty.append(symbol, el("strong", "", filter ? "Nenhum item nesta página" : "Nenhum registro disponível"),
        el("span", "", filter ? "Altere o filtro ou navegue para outra página." : "Esta página não possui registros visíveis para sua conta."));
      records.append(empty);
    } else {
      for (const row of visible) {
        const data = info(row);
        const record = el("article", "record");
        const icon = el("div", "avatar " + state.view.slice(0, -1), data.initial || "•");
        const content = el("div", "record-main");
        content.append(el("div", "record-name", data.name), el("div", "record-sub", data.sub));
        const side = el("div", "record-side");
        side.append(el("span", "tag" + (data.off ? " off" : ""), data.tag), el("span", "record-detail", data.detail));
        if (data.progress !== undefined && data.progress !== null) {
          const progress = el("div", "quota-progress");
          const fill = el("i", data.progress >= 80 ? "high" : "");
          fill.style.width = data.progress + "%";
          progress.setAttribute("role", "progressbar");
          progress.setAttribute("aria-label", "Consumo da franquia");
          progress.setAttribute("aria-valuemin", "0");
          progress.setAttribute("aria-valuemax", "100");
          progress.setAttribute("aria-valuenow", String(data.progress));
          progress.append(fill);
          side.append(progress);
        }
        record.append(icon, content, side);
        records.append(record);
      }
    }
    $("resultCount").textContent = number.format(visible.length) + " nesta página" + (filter ? " (filtrados)" : "");
    $("pageNumber").textContent = String(state.page + 1);
    $("pageIndicator").textContent = "PÁGINA " + String(state.page + 1).padStart(2, "0");
    $("prevButton").disabled = state.loading || state.page === 0;
    $("nextButton").disabled = state.loading || !state.hasMore;
    $("pageMeta").textContent = "Até " + state.limit + " registros por página · acesso limitado à sua conta";
    records.setAttribute("aria-busy", "false");
  };
  const loading = (isLoading) => {
    state.loading = isLoading;
    $("refreshButton").disabled = isLoading;
    $("prevButton").disabled = isLoading || state.page === 0;
    $("nextButton").disabled = isLoading || !state.hasMore;
    if (isLoading) {
      $("records").setAttribute("aria-busy", "true");
      $("records").replaceChildren(...Array.from({ length: 3 }, () => el("div", "skeleton")));
    }
  };
  const load = async () => {
    const requestToken = ++state.token;
    state.controller?.abort();
    const controller = new AbortController();
    state.controller = controller;
    showNotice("");
    loading(true);
    if (!app || typeof app.initData !== "string" || !app.initData.length) {
      loading(false);
      state.rows = [];
      state.hasMore = false;
      status("failed", "Sem autenticação");
      showNotice("Abra este painel pelo botão Mini App do bot no Telegram. Não é possível consultar dados fora de uma sessão autenticada.");
      return draw();
    }
    try {
      const response = await fetch("/api/read", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        cache: "no-store",
        credentials: "omit",
        referrerPolicy: "no-referrer",
        signal: controller.signal,
        body: JSON.stringify({ init_data: app.initData, view: state.view, page: state.page, limit: state.limit }),
      });
      const payload = await response.json();
      if (!response.ok || payload.ok !== true) {
        if (response.status === 403) throw new Error("Acesso recusado ou autenticação Telegram expirada. Reabra o Mini App pelo bot.");
        if (response.status === 429) throw new Error("Muitas consultas. Aguarde um pouco antes de atualizar.");
        throw new Error("Não foi possível carregar os dados. Tente novamente.");
      }
      if (!payload.data || payload.data.view !== state.view || payload.data.page !== state.page || !Array.isArray(payload.data.items)) {
        throw new Error("O servidor retornou uma resposta inválida.");
      }
      if (requestToken !== state.token) return;
      state.rows = payload.data.items;
      state.hasMore = payload.data.has_more === true;
      status("connected", "Conexão segura");
    } catch (e) {
      if (controller.signal.aborted || requestToken !== state.token) return;
      state.rows = [];
      state.hasMore = false;
      status("failed", "Indisponível");
      showNotice(e instanceof Error ? e.message : "Não foi possível conectar ao MANAGER.");
    } finally {
      if (requestToken === state.token) {
        loading(false);
        draw();
      }
    }
  };
  const selectView = (view) => {
    if (!views[view] || view === state.view) return;
    state.view = view;
    state.page = 0;
    state.rows = [];
    state.hasMore = false;
    $("searchInput").value = "";
    $("sectionTitle").textContent = views[view].title;
    $("sectionKicker").textContent = views[view].kicker;
    $("sectionSubtitle").textContent = views[view].subtitle;
    tabs.forEach((tab) => {
      const selected = tab.dataset.view === view;
      tab.classList.toggle("selected", selected);
      if (selected) tab.setAttribute("aria-current", "page");
      else tab.removeAttribute("aria-current");
    });
    load();
  };
  tabs.forEach((tab) => tab.addEventListener("click", () => selectView(tab.dataset.view)));
  $("refreshButton").addEventListener("click", load);
  $("searchInput").addEventListener("input", draw);
  $("prevButton").addEventListener("click", () => { if (state.page > 0) { state.page -= 1; $("searchInput").value = ""; load(); } });
  $("nextButton").addEventListener("click", () => { if (state.hasMore && state.page < 100000) { state.page += 1; $("searchInput").value = ""; load(); } });
  if (app) {
    try { app.ready(); app.expand(); app.setHeaderColor?.("secondary_bg_color"); } catch (_) { /* Unsupported clients */ }
  }
  load();
})();
