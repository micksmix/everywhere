const copyButton = document.querySelector('#copy-install');
copyButton.addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(document.querySelector('#install-command').textContent);
    status.textContent = 'Install commands copied.';
    copyButton.textContent = 'Copied';
  } catch {
    status.textContent = 'Select and copy the commands above.';
  }
});
