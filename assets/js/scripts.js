let debounceTimeout;

function copyCommand(url, prefix, postfix) {
  const command = `${prefix} "${url}" | ${postfix}`;

  if (debounceTimeout) clearTimeout(debounceTimeout);

  navigator.clipboard.writeText(command).then(() => {
    const notification = document.getElementById('copy-notification');
    notification.textContent = 'Command copied to clipboard';
    notification.style.backgroundColor = 'var(--copy-notification-bg)';
    notification.style.display = 'block';
    notification.focus();
    debounceTimeout = setTimeout(() => notification.style.display = 'none', 2000);
  }).catch(() => {
    const notification = document.getElementById('copy-notification');
    notification.textContent = 'Failed to copy command';
    notification.style.backgroundColor = 'var(--copy-notification-bg-error)';
    notification.style.display = 'block';
    debounceTimeout = setTimeout(() => notification.style.display = 'none', 3000);
  });
}

function toggleDropdown(button) {
  const dropdownContent = button.nextElementSibling;
  document.querySelectorAll('.dropdown-content').forEach(content => {
    if (content !== dropdownContent) content.classList.remove('show');
  });
  dropdownContent.classList.toggle('show');
}

document.addEventListener('click', (event) => {
  if (!event.target.closest('.dropdown')) {
    document.querySelectorAll('.dropdown-content.show').forEach(content => content.classList.remove('show'));
  }
});
