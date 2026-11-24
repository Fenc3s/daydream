const menuID = "daydream-save-image-to-photos";
const nativeHostName = "com.daydream.app";

function registerContextMenu() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: menuID,
      title: "Save Image to Photos",
      contexts: ["image"]
    });
  });
}

chrome.runtime.onInstalled.addListener(registerContextMenu);
chrome.runtime.onStartup.addListener(registerContextMenu);
registerContextMenu();

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId !== menuID || !info.srcUrl) {
    return;
  }

  chrome.runtime.sendNativeMessage(
    nativeHostName,
    {
      action: "saveImageToPhotos",
      url: info.srcUrl
    },
    (response) => {
      if (chrome.runtime.lastError) {
        console.error("Daydream native messaging failed:", chrome.runtime.lastError.message);
        return;
      }

      if (!response?.ok) {
        console.error("Daydream could not save the image:", response?.error ?? "Unknown error");
      }
    }
  );
});
