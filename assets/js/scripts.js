function copyCommand(url, prefix, postfix) {
  const command = `${prefix} "${url}" | ${postfix}`;

  navigator.clipboard.writeText(command).then(() => {
    const notification = document.getElementById('copy-notification');
    notification.style.display = 'block';
    setTimeout(() => notification.style.display = 'none', 2000);
  }).catch(() => {
    alert(`Failed to copy! Command:\n\n${command}`);
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
