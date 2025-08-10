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
  
  // Don't show count initially - only when filtering
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
  const scriptCount = document.getElementById('script-count');
  
  if (!searchInput || !typeFilter) return;
  
  const searchTerm = searchInput.value.toLowerCase();
  const typeFilterValue = typeFilter.value;
  
  // Check if there's an active search or filter
  const hasActiveSearch = searchTerm.length > 0;
  const hasActiveFilter = typeFilterValue !== 'all';
  const isFiltering = hasActiveSearch || hasActiveFilter;
  
  // Show/hide script count based on filtering state using CSS classes
  if (scriptCount) {
    if (isFiltering) {
      scriptCount.classList.add('show');
    } else {
      scriptCount.classList.remove('show');
    }
  }
  
  let filteredScripts = allScripts.filter(script => {
    const matchesSearch = script.name.includes(searchTerm);
    const matchesType = typeFilterValue === 'all' || script.type === typeFilterValue;
    return matchesSearch && matchesType;
  });
  
  // Always apply sorting
  filteredScripts.sort((a, b) => {
    if (currentSort === 'asc') {
      return a.name.localeCompare(b.name);
    } else {
      return b.name.localeCompare(a.name);
    }
  });
  
  displayFilteredScripts(filteredScripts);
  
  // Update results count when filtering
  if (isFiltering) {
    updateResultsCount(filteredScripts.length);
  }
}

function displayFilteredScripts(filteredScripts) {
  const container = document.getElementById('scripts-container');
  const noResults = document.getElementById('no-results');
  const sections = document.querySelectorAll('.script-type-section');
  
  if (!container || !noResults) return;
  
  // Hide all sections and scripts using class-based approach
  sections.forEach(section => section.classList.add('hide'));
  allScripts.forEach(script => script.element.classList.add('hide'));
  
  if (filteredScripts.length === 0) {
    noResults.classList.remove('hide');
    return;
  }
  
  noResults.classList.add('hide');
  
  // Group filtered scripts by type (they're already sorted)
  const scriptsByType = {};
  filteredScripts.forEach(script => {
    if (!scriptsByType[script.type]) {
      scriptsByType[script.type] = [];
    }
    scriptsByType[script.type].push(script);
  });
  
  // Show sections in the original order (linux, windows, python)
  const orderedTypes = ['linux', 'windows', 'python'];
  orderedTypes.forEach(type => {
    if (scriptsByType[type]) {
      const section = document.querySelector(`.script-type-section[data-type="${type}"]`);
      if (section) {
        section.classList.remove('hide');
        
        const grid = section.querySelector('.related-wrapper');
        if (grid) {
          grid.innerHTML = '';
          
          scriptsByType[type].forEach(script => {
            script.element.classList.remove('hide');
            grid.appendChild(script.element);
          });
        }
      }
    }
  });
}

function toggleSort() {
  currentSort = currentSort === 'asc' ? 'desc' : 'asc';
  const sortButton = document.getElementById('sort-toggle');
  
  if (sortButton) {
    if (currentSort === 'asc') {
      sortButton.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="none" viewBox="0 0 640 640">
          <path d="M342.6 81.4c-12.5-12.5-32.8-12.5-45.3 0l-160 160c-12.5 12.5-12.5 32.8 0 45.3s32.8 12.5 45.3 0L288 181.3V552c0 17.7 14.3 32 32 32s32-14.3 32-32V181.3l105.4 105.4c12.5 12.5 32.8 12.5 45.3 0s12.5-32.8 0-45.3l-160-160z" fill="currentColor"/>
        </svg> A-Z`;
    } else {
      sortButton.innerHTML = `
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="none" viewBox="0 0 640 640">
          <path d="M297.4 566.6c12.5 12.5 32.8 12.5 45.3 0l160-160c12.5-12.5 12.5-32.8 0-45.3s-32.8-12.5-45.3 0L352 466.7V96c0-17.7-14.3-32-32-32s-32 14.3-32 32v370.7L182.6 361.3c-12.5-12.5-32.8-12.5-45.3 0s-12.5 32.8 0 45.3l160 160z" fill="currentColor"/>
        </svg> Z-A`;
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

function redirectToGitHub(cardElement) {
  const scriptUrl = cardElement.dataset.scriptUrl;
  const scriptName = cardElement.dataset.name;
  
  const githubBaseUrl = 'https://github.com/EdoardoTosin/tools/blob/main/script/';
  const githubRawUrl = githubBaseUrl + scriptName;
  
  window.open(githubRawUrl, '_blank');
}

function downloadScript(scriptUrl, filename) {
  // Create a temporary notification
  const notification = document.getElementById('copy-notification');
  if (notification) {
    notification.textContent = 'Downloading script...';
    notification.style.display = 'block';
    notification.classList.add('show');
  }
  
  // Use the same GitHub raw URL pattern as the redirect function
  const githubBaseUrl = 'https://raw.githubusercontent.com/EdoardoTosin/tools/refs/heads/main/script/';
  const githubRawUrl = githubBaseUrl + filename;
  
  fetch(githubRawUrl)
    .then(response => {
      if (!response.ok) {
        throw new Error(`Failed to fetch script: ${response.status}`);
      }
      return response.blob();
    })
    .then(blob => {
      // Create download link
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.style.display = 'none';
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      window.URL.revokeObjectURL(url);
      document.body.removeChild(a);
      
      // Show success notification
      if (notification) {
        notification.textContent = 'Script downloaded successfully!';
        setTimeout(() => {
          notification.style.display = 'none';
          notification.classList.remove('show');
        }, 2000);
      }
    })
    .catch(error => {
      console.error('Download failed:', error);
      // Show error notification
      if (notification) {
        notification.textContent = 'Download failed. Please try again.';
        notification.style.background = 'var(--copy-notification-bg-error)';
        setTimeout(() => {
          notification.style.display = 'none';
          notification.classList.remove('show');
          notification.style.background = 'var(--copy-notification-bg)';
        }, 3000);
      }
    });
}
