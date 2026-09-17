document.querySelectorAll('[data-copy]').forEach((button) => {
  button.addEventListener('click', async () => {
    const status = button.closest('.install-panel').querySelector('.copy-status');
    try {
      await navigator.clipboard.writeText(document.getElementById(button.dataset.copy).textContent);
      status.textContent = 'Install commands copied.';
      button.textContent = 'Copied';
    } catch {
      status.textContent = 'Select and copy the commands above.';
    }
  });
});
