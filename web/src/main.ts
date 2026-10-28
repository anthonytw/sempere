import "./style.css";
import { initLocale } from "./i18n/index.ts";
import { App } from "./ui/app.ts";

initLocale();
const root = document.getElementById("app");
if (root) new App(root).start();
