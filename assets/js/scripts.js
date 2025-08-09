let currentSort = 'asc';
let allScripts = [];
let debounceTimeout;

document.addEventListener('DOMContentLoaded', function() {
  initializeScripts();
  setupEventListeners();
});

function initializeScripts() {
  const scriptCards = document.querySelectorAll('.script-card');
  allScripts = Array.from(scriptCards).map(card => ({
    element: card,
    name: card.dataset.name,
    type: card.dataset.type,
    section: card.closest('.script-type-section')
  }));
  
  updateResultsCount();
}

function setupEventListeners() {
  const searchInput = document.getElementById('script-search');
  const typeFilter = document.getElementById('type-filter');
  const sortToggle = document.getElementById('sort-toggle');
  
  if (searchInput) searchInput.addEventListener('input', filterAndSortScripts);
  if (typeFilter) typeFilter.addEventListener('change', filterAndSortScripts);
  if (sortToggle) sortToggle.addEventListener('click', toggleSort);
  
  document.addEventListener('click', (event) => {
    if (!event.target.closest('.python-dropdown')) {
      document.querySelectorAll('.dropdown-content.show').forEach(content => {
        content.classList.remove('show');
        const parentDropdown = content.closest('.python-dropdown');
        if (parentDropdown) {
          parentDropdown.classList.remove('active');
        }
      });
    }
  });
}

function filterAndSortScripts() {
  const searchInput = document.getElementById('script-search');
  const typeFilter = document.getElementById('type-filter');
  
  if (!searchInput || !typeFilter) return;
  
  const searchTerm = searchInput.value.toLowerCase();
  const typeFilterValue = typeFilter.value;
  
  let filteredScripts = allScripts.filter(script => {
    const matchesSearch = script.name.includes(searchTerm);
    const matchesType = typeFilterValue === 'all' || script.type === typeFilterValue;
    return matchesSearch && matchesType;
  });
  
  filteredScripts.sort((a, b) => {
    if (currentSort === 'asc') {
      return a.name.localeCompare(b.name);
    } else {
      return b.name.localeCompare(a.name);
    }
  });
  
  displayFilteredScripts(filteredScripts);
  updateResultsCount(filteredScripts.length);
}

function displayFilteredScripts(filteredScripts) {
  const container = document.getElementById('scripts-container');
  const noResults = document.getElementById('no-results');
  const sections = document.querySelectorAll('.script-type-section');
  
  if (!container || !noResults) return;
  
  sections.forEach(section => section.style.display = 'none');
  
  allScripts.forEach(script => script.element.style.display = 'none');
  
  if (filteredScripts.length === 0) {
    noResults.style.display = 'block';
    return;
  }
  
  noResults.style.display = 'none';
  
  const scriptsByType = {};
  filteredScripts.forEach(script => {
    if (!scriptsByType[script.type]) {
      scriptsByType[script.type] = [];
    }
    scriptsByType[script.type].push(script);
  });
  
  Object.keys(scriptsByType).forEach(type => {
    const section = document.querySelector(`.script-type-section[data-type="${type}"]`);
    if (section) {
      section.style.display = 'block';
      
      const grid = section.querySelector('.scripts-grid');
      if (grid) {
        grid.innerHTML = '';
        
        scriptsByType[type].forEach(script => {
          script.element.style.display = 'block';
          grid.appendChild(script.element);
        });
      }
    }
  });
}

function toggleSort() {
  currentSort = currentSort === 'asc' ? 'desc' : 'asc';
  const sortButton = document.getElementById('sort-toggle');
  
  if (sortButton) {
    if (currentSort === 'asc') {
      sortButton.innerHTML = '<span id="sort-icon">↑</span> A-Z';
    } else {
      sortButton.innerHTML = '<span id="sort-icon">↓</span> Z-A';
    }
  }
  
  filterAndSortScripts();
}

function updateResultsCount(count = null) {
  const resultsCount = document.getElementById('results-count');
  if (resultsCount) {
    const totalCount = count !== null ? count : allScripts.length;
    resultsCount.textContent = totalCount;
  }
}

function copyCommand(url, prefix, postfix) {
  const command = `${prefix} "${url}" | ${postfix}`;

  if (debounceTimeout) clearTimeout(debounceTimeout);

  document.querySelectorAll('.dropdown-content.show').forEach(content => {
    content.classList.remove('show');
    const parentDropdown = content.closest('.python-dropdown');
    if (parentDropdown) parentDropdown.classList.remove('active');
  });

  navigator.clipboard.writeText(command).then(() => {
    const notification = document.getElementById('copy-notification');
    if (notification) {
      notification.textContent = 'Command copied to clipboard';
      notification.style.display = 'block';
      notification.classList.add('show');
      notification.focus();
      debounceTimeout = setTimeout(() => {
        notification.style.display = 'none';
        notification.classList.remove('show');
      }, 2000);
    }
  }).catch(() => {
    const notification = document.getElementById('copy-notification');
    if (notification) {
      notification.textContent = 'Failed to copy command';
      notification.style.display = 'block';
      notification.classList.add('show');
      debounceTimeout = setTimeout(() => {
        notification.style.display = 'none';
        notification.classList.remove('show');
      }, 3000);
    }
  });
}

function toggleDropdown(button) {
  const dropdownContent = button.nextElementSibling;
  const dropdown = button.closest('.python-dropdown');
  
  document.querySelectorAll('.dropdown-content').forEach(content => {
    if (content !== dropdownContent) {
      content.classList.remove('show');
      const parentDropdown = content.closest('.python-dropdown');
      if (parentDropdown) {
        parentDropdown.classList.remove('active');
      }
    }
  });
  
  if (dropdown) {
    dropdown.classList.toggle('active');
  }
  dropdownContent.classList.toggle('show');
}
