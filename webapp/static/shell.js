(function () {
  var toggle = document.querySelector('[data-sidebar-toggle]');
  var sidebar = document.querySelector('[data-sidebar]');
  var overlay = document.querySelector('[data-sidebar-overlay]');
  if (!toggle || !sidebar || !overlay) return;

  function setOpen(open) {
    sidebar.classList.toggle('-translate-x-full', !open);
    overlay.classList.toggle('hidden', !open);
  }
  toggle.addEventListener('click', function () { setOpen(true); });
  overlay.addEventListener('click', function () { setOpen(false); });
})();
