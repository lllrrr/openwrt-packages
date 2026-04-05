import { Dialog } from "@/components/Dialog";

const dialog = new Dialog();
let isMounted = false;

function ensureMounted() {
  if (isMounted) return;
  if (document.body) {
    document.body.appendChild(dialog.render());
    isMounted = true;
  }
}

export function alert(
  message: string | HTMLElement | (string | HTMLElement)[],
  title?: string,
): Promise<boolean> {
  ensureMounted();
  return dialog.open({
    type: "alert",
    message,
    title,
  });
}

export function confirm(
  message: string | HTMLElement | (string | HTMLElement)[],
  title?: string,
): Promise<boolean> {
  ensureMounted();
  return dialog.open({
    type: "confirm",
    message,
    title,
  });
}
