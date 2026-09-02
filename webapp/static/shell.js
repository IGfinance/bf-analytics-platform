(function () {
  var navToggle = document.querySelector('[data-mobile-nav-toggle]');
  var nav = document.querySelector('[data-mobile-nav]');
  if (navToggle && nav) {
    navToggle.addEventListener('click', function () {
      nav.classList.toggle('hidden');
    });
  }

  var switcher = document.querySelector('[data-project-switcher]');
  var switcherToggle = document.querySelector('[data-project-switcher-toggle]');
  var switcherMenu = document.querySelector('[data-project-switcher-menu]');
  if (switcher && switcherToggle && switcherMenu) {
    switcherToggle.addEventListener('click', function (e) {
      e.stopPropagation();
      switcherMenu.classList.toggle('hidden');
    });
    document.addEventListener('click', function (e) {
      if (!switcher.contains(e.target)) switcherMenu.classList.add('hidden');
    });
  }
})();
