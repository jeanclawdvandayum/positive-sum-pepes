// greenlist app — public form + admin desk (vanilla, no deps)
(() => {
  // shared: theme toggle mirror of the alt UI
  document.getElementById('theme')?.addEventListener('click', () => {
    const html = document.documentElement
    const light = html.dataset.theme === 'light'
    html.dataset.theme = light ? 'dark' : 'light'
    localStorage.setItem('psp-theme', light ? 'dark' : 'light')
  })

  // ── apply page ────────────────────────────────────────────────────────────
  const form = document.getElementById('form')
  if (form) {
    const address = document.getElementById('address')
    const addrErr = document.getElementById('addr-err')
    const drop = document.getElementById('drop')
    const picker = document.getElementById('meme')
    const pick = document.getElementById('pick')
    const preview = document.getElementById('preview')
    const hint = document.getElementById('drop-hint')
    const memeErr = document.getElementById('meme-err')
    const note = document.getElementById('note')
    const send = document.getElementById('send')
    let chosen = null

    const isEth = a => /^0x[0-9a-fA-F]{40}$/.test(a)
    address.addEventListener('input', () => {
      addrErr.hidden = !address.value || isEth(address.value.trim())
    })

    const accept = file => {
      if (!file) return
      const okType = /image\/(png|jpe?g)/.test(file.type) || /\.(png|jpe?g)$/i.test(file.name)
      if (!okType || file.size > 8 * 1024 * 1024) { memeErr.hidden = false; return }
      memeErr.hidden = true
      chosen = file
      preview.src = URL.createObjectURL(file)
      preview.hidden = false
      hint.innerHTML = `${file.name} · ${(file.size / 1024 / 1024).toFixed(2)} MB`
    }
    pick.addEventListener('click', () => picker.click())
    picker.addEventListener('change', () => accept(picker.files[0]))
    ;['dragover', 'dragenter'].forEach(e => drop.addEventListener(e, ev => {
      ev.preventDefault(); drop.classList.add('over')
    }))
    ;['dragleave', 'drop'].forEach(e => drop.addEventListener(e, ev => {
      ev.preventDefault(); drop.classList.remove('over')
    }))
    drop.addEventListener('drop', ev => accept(ev.dataTransfer.files[0]))
    preview.addEventListener('click', () => picker.click())

    form.addEventListener('submit', async ev => {
      ev.preventDefault()
      note.textContent = ''
      const a = address.value.trim()
      if (!isEth(a)) { addrErr.hidden = false; return }
      if (!chosen) { memeErr.hidden = false; return }
      const body = new FormData()
      body.set('address', a.toLowerCase())
      body.set('meme', chosen)
      send.disabled = true; send.textContent = 'sending…'
      try {
        const res = await fetch('/api/apply', { method: 'POST', body })
        if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || 'submission failed')
        note.textContent = 'received. one meme per address — that\'s the one that counts.'
        chosen = null; picker.value = ''
        preview.hidden = true
        hint.innerHTML = 'drop an image here<br>or'
      } catch (e) {
        note.textContent = e.message
      } finally {
        send.disabled = false; send.textContent = 'send it in ↗'
      }
    })
  }

  // ── admin page ────────────────────────────────────────────────────────────
  const login = document.getElementById('login')
  if (login) {
    const tokenInput = document.getElementById('token')
    const loginErr = document.getElementById('login-err')
    const desk = document.getElementById('desk')
    let token = sessionStorage.getItem('gl-token') || ''

    const api = (path, opts = {}) => fetch(path, {
      ...opts,
      headers: { authorization: `Bearer ${token}`, ...(opts.headers || {}) },
    })

    const decide = async (id, status) => {
      const res = await api(`/api/submissions/${id}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ status }),
      })
      if (res.ok) load()
    }

    const load = async () => {
      const res = await api('/api/submissions')
      if (res.status === 401) { login.hidden = false; desk.hidden = true; return }
      const rows = await res.json()
      const grid = document.getElementById('grid')
      grid.innerHTML = ''
      const counts = { pending: 0, approved: 0, denied: 0 }
      for (const r of rows) {
        counts[r.status]++
        const card = document.createElement('div')
        card.className = `gl-sub card ${r.status}`
        card.innerHTML = `
          <img src="${r.meme}" alt="meme from ${r.address}" loading="lazy">
          <div class="gl-sub-meta">
            <code>${r.address}</code>
            <span class="gl-status">${r.status}</span>
          </div>
          <div class="gl-sub-actions">
            <button class="st-btn" data-a="approved">spot earned ✓</button>
            <button class="st-btn" data-a="denied">no spot ✕</button>
            <button class="st-btn" data-a="pending">reset</button>
          </div>`
        card.querySelectorAll('button').forEach(b =>
          b.addEventListener('click', () => decide(r.id, b.dataset.a)))
        grid.appendChild(card)
      }
      document.getElementById('counts').textContent =
        `${rows.length} memes · ${counts.pending} pending · ${counts.approved} approved · ${counts.denied} denied`
      document.getElementById('export').href = `/api/export.csv?token=${encodeURIComponent(token)}`
    }

    const open = async () => {
      loginErr.textContent = ''
      const res = await fetch('/api/submissions', { headers: { authorization: `Bearer ${token}` } })
      if (res.status === 401) { loginErr.textContent = 'wrong token.'; return }
      sessionStorage.setItem('gl-token', token)
      login.hidden = true; desk.hidden = false
      load()
    }
    document.getElementById('go').addEventListener('click', () => { token = tokenInput.value.trim(); open() })
    tokenInput.addEventListener('keydown', e => { if (e.key === 'Enter') { token = tokenInput.value.trim(); open() } })
    document.getElementById('refresh').addEventListener('click', load)
    if (token) open()
  }
})()
