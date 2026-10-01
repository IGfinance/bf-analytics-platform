(function () {
  var navToggle = document.querySelector('[data-mobile-nav-toggle]');
  var nav = document.querySelector('[data-mobile-nav]');
  if (navToggle && nav) {
    navToggle.addEventListener('click', function () {
      nav.classList.toggle('hidden');
    });
  }

  // ---------- Выпадающий список (partials/ui.html: ui_select) ----------
  var selects = document.querySelectorAll('[data-ui-select]');

  function closeAll(except) {
    selects.forEach(function (root) {
      if (root === except) return;
      var list = root.querySelector('.ui-select__list');
      var btn = root.querySelector('.ui-select__button');
      if (list && !list.hidden) { list.hidden = true; btn.setAttribute('aria-expanded', 'false'); }
    });
  }

  function options(root) { return Array.prototype.slice.call(root.querySelectorAll('.ui-select__option')); }

  function openList(root) {
    closeAll(root);
    var list = root.querySelector('.ui-select__list');
    var btn = root.querySelector('.ui-select__button');
    list.hidden = false;
    btn.setAttribute('aria-expanded', 'true');
    var sel = list.querySelector('[aria-selected="true"]') || options(root)[0];
    if (sel) sel.focus();
  }

  function closeList(root, focusButton) {
    var list = root.querySelector('.ui-select__list');
    var btn = root.querySelector('.ui-select__button');
    list.hidden = true;
    btn.setAttribute('aria-expanded', 'false');
    if (focusButton) btn.focus();
  }

  function choose(root, opt) {
    var href = opt.getAttribute('data-href');
    if (href) { window.location = href; return; }     // опция-ссылка (переключатель проекта)
    options(root).forEach(function (o) { o.setAttribute('aria-selected', o === opt ? 'true' : 'false'); });
    var valueEl = root.querySelector('[data-ui-select-value]');
    valueEl.textContent = opt.querySelector('span').textContent;
    valueEl.classList.remove('ui-select__value--placeholder');
    var input = root.querySelector('[data-ui-select-input]');
    if (input) input.value = opt.getAttribute('data-value');
    closeList(root, true);
    root.dispatchEvent(new CustomEvent('ui-select-change', {
      bubbles: true,
      detail: { value: opt.getAttribute('data-value'), meta: opt.getAttribute('data-meta') || '' }
    }));
  }

  selects.forEach(function (root) {
    var btn = root.querySelector('.ui-select__button');
    var list = root.querySelector('.ui-select__list');
    btn.addEventListener('click', function () { list.hidden ? openList(root) : closeList(root, false); });
    btn.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); openList(root); }
    });
    list.addEventListener('click', function (e) {
      var opt = e.target.closest('.ui-select__option');
      if (opt) choose(root, opt);
    });
    list.addEventListener('keydown', function (e) {
      var opts = options(root);
      var i = opts.indexOf(document.activeElement);
      if (e.key === 'ArrowDown') { e.preventDefault(); opts[Math.min(i + 1, opts.length - 1)].focus(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); opts[Math.max(i - 1, 0)].focus(); }
      else if (e.key === 'Home') { e.preventDefault(); opts[0].focus(); }
      else if (e.key === 'End') { e.preventDefault(); opts[opts.length - 1].focus(); }
      else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); if (i >= 0) choose(root, opts[i]); }
      else if (e.key === 'Escape' || e.key === 'Tab') { closeList(root, e.key === 'Escape'); }
    });
  });

  document.addEventListener('click', function (e) {
    var inside = e.target.closest('[data-ui-select]');
    closeAll(inside);
  });

  // ---------- «Загрузка»: кабинет включает/выключает двери по площадкам ----------
  var cabinetSelect = document.querySelector('[data-cabinet-select]');
  if (cabinetSelect) {
    var mirrors = document.querySelectorAll('[data-cabinet-mirror]');
    var doors = document.querySelectorAll('[data-door][data-platform]');
    var PLATFORM_NAMES = { wb: 'WB', ozon: 'Ozon' };

    var applyCabinet = function (value, meta) {
      var platforms = meta ? meta.split(',') : [];
      mirrors.forEach(function (m) { m.value = value; });
      doors.forEach(function (door) {
        var ok = !!value && platforms.indexOf(door.getAttribute('data-platform')) !== -1;
        var btn = door.querySelector('[data-needs-cabinet]');
        var hint = door.querySelector('[data-cabinet-hint]');
        door.classList.toggle('door-unavailable', !!value && !ok);
        if (btn) btn.disabled = !ok;
        if (hint) {
          hint.textContent = !value ? 'Сначала выберите кабинет.'
            : ok ? '' : 'У кабинета «' + value + '» нет площадки ' + PLATFORM_NAMES[door.getAttribute('data-platform')] + '.';
        }
      });
    };

    cabinetSelect.addEventListener('ui-select-change', function (e) { applyCabinet(e.detail.value, e.detail.meta); });
    var preset = cabinetSelect.querySelector('[aria-selected="true"]');
    if (preset) applyCabinet(preset.getAttribute('data-value'), preset.getAttribute('data-meta') || '');
  }
})();
