import csv
import json
import os
import subprocess
import sys
import tempfile
from copy import deepcopy
from pathlib import Path

from PySide6.QtCore import QSize, Qt, QThread, Signal
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QDialog,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QSpinBox,
    QToolButton,
    QVBoxLayout,
    QWidget,
)


BASE_DIR = Path(__file__).resolve().parent
SETTINGS_PATH = BASE_DIR / "settings.json"
SEQUENCE_PATH = BASE_DIR / "sequence.json"
PROJECT_SETTINGS_PATH = BASE_DIR / "project_settings.json"
RENAME_SCRIPT_PATH = BASE_DIR / "rename_logic.ps1"
LOG_PATH = BASE_DIR / "naming_log.csv"
ASSETS_DIR = BASE_DIR / "assets"
IGNORED_NAMES = {
    "settings.json",
    "sequence.json",
    "naming_log.csv",
    "naming_log_backup.csv",
    "project_settings.json",
    "assets",
    "__pycache__",
}

PROJECTS = {
    "雷霆战机": "雷霆",
    "英雄请出战": "英雄",
}

PROJECT_LOGOS = {
    "雷霆战机": [
        ASSETS_DIR / "thunder_icon.jpg",
        Path(r"Z:\雷霆战机（中转文件）\雷霆战机平面素材\UI\ICON.jpg"),
    ],
    "英雄请出战": [
        ASSETS_DIR / "hero_icon.png",
    ],
}


def read_json(path, default):
    if not path.exists():
        return deepcopy(default)
    text = path.read_text(encoding="utf-8-sig").strip()
    if not text:
        return deepcopy(default)
    return json.loads(text)


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=4), encoding="utf-8-sig")


def normalize_folder(path_text):
    path_text = path_text.strip()
    if not path_text:
        return ""
    return os.path.normpath(path_text)


def load_or_create_project_settings():
    if PROJECT_SETTINGS_PATH.exists():
        data = read_json(PROJECT_SETTINGS_PATH, {})
        data.setdefault("projects", {})
        changed = False
        first_project = next(iter(data["projects"].values()), {})

        for name, suffix in PROJECTS.items():
            if name not in data["projects"]:
                data["projects"][name] = {
                    "suffix": suffix,
                    "image_out_dir": first_project.get("image_out_dir", ""),
                    "video_out_dir": first_project.get("video_out_dir", ""),
                    "image_seq": int(first_project.get("image_seq", 1)),
                    "video_seq": int(first_project.get("video_seq", 1)),
                }
                changed = True
            else:
                project = data["projects"][name]
                project["suffix"] = suffix
                project["image_out_dir"] = normalize_folder(project.get("image_out_dir", ""))
                project["video_out_dir"] = normalize_folder(project.get("video_out_dir", ""))
                project["image_seq"] = int(project.get("image_seq", 1))
                project["video_seq"] = int(project.get("video_seq", 1))

        if data.get("current_project") not in PROJECTS:
            data["current_project"] = "雷霆战机"
            changed = True
        if changed:
            write_json(PROJECT_SETTINGS_PATH, data)
        return data

    settings = read_json(SETTINGS_PATH, {})
    sequence = read_json(SEQUENCE_PATH, {"image_seq": 1, "video_seq": 1})
    thunder = {
        "suffix": PROJECTS["雷霆战机"],
        "image_out_dir": normalize_folder(settings.get("IMAGE_OUT_DIR", "")),
        "video_out_dir": normalize_folder(settings.get("VIDEO_OUT_DIR", "")),
        "image_seq": int(sequence.get("image_seq", 1)),
        "video_seq": int(sequence.get("video_seq", 1)),
    }
    hero = deepcopy(thunder)
    hero["suffix"] = PROJECTS["英雄请出战"]
    data = {
        "current_project": "雷霆战机",
        "projects": {
            "雷霆战机": thunder,
            "英雄请出战": hero,
        },
    }
    write_json(PROJECT_SETTINGS_PATH, data)
    return data


def write_runtime_config(project):
    settings = read_json(SETTINGS_PATH, {})
    settings["IMAGE_OUT_DIR"] = project["image_out_dir"]
    settings["VIDEO_OUT_DIR"] = project["video_out_dir"]
    write_json(SETTINGS_PATH, settings)

    write_json(
        SEQUENCE_PATH,
        {
            "image_seq": int(project["image_seq"]),
            "video_seq": int(project["video_seq"]),
        },
    )


def ignored_workspace_item(path):
    name = path.name
    lower_name = name.lower()
    return (
        name in IGNORED_NAMES
        or name.startswith(".")
        or lower_name.endswith((".bat", ".ps1", ".py", ".zip"))
    )


def has_digit_marker(path, number):
    stem = path.stem
    marker = str(number)
    padded = f"0{number}"
    parts = []
    current = ""
    for char in stem:
        if char.isdigit():
            current += char
        elif current:
            parts.append(current)
            current = ""
    if current:
        parts.append(current)
    return marker in parts or padded in parts


def is_complete_nine_image_folder(path):
    if not path.is_dir() or ignored_workspace_item(path):
        return False
    files = [child for child in path.iterdir() if child.is_file()]
    if len(files) < 9:
        return False
    return all(any(has_digit_marker(file_path, index) for file_path in files) for index in range(1, 10))


def scan_works():
    settings = read_json(SETTINGS_PATH, {})
    img_exts = {ext.lower() for ext in settings.get("IMG_EXTS", [])}
    vid_exts = {ext.lower() for ext in settings.get("VID_EXTS", [])}
    works = []
    nine_folders = []

    for item in BASE_DIR.iterdir():
        if ignored_workspace_item(item):
            continue
        if item.is_dir():
            if is_complete_nine_image_folder(item):
                works.append(item)
                nine_folders.append(item)
            continue
        if item.suffix.lower() in img_exts or item.suffix.lower() in vid_exts:
            works.append(item)

    return works, nine_folders


def log_line_count():
    if not LOG_PATH.exists():
        return 0
    with LOG_PATH.open("r", encoding="utf-8-sig", newline="") as handle:
        return sum(1 for _ in handle)


def read_new_log_rows(start_line):
    if not LOG_PATH.exists():
        return []
    with LOG_PATH.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    return rows[max(0, start_line - 1) :]


def detect_category(name):
    for category in ("横视频", "竖视频", "横图", "竖图", "方图", "9图"):
        if category in name:
            return category
    return "未知"


def available_logo_path(project_name):
    for path in PROJECT_LOGOS.get(project_name, []):
        if path.exists():
            return str(path)
    return ""


class RenameWorker(QThread):
    finished_ok = Signal(int)
    failed = Signal(str)

    def __init__(self, suffix, log_start_line, folder_name_map_path=""):
        super().__init__()
        self.suffix = suffix
        self.log_start_line = log_start_line
        self.folder_name_map_path = folder_name_map_path

    def run(self):
        command = [
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(RENAME_SCRIPT_PATH),
            "-ProjectSuffix",
            self.suffix,
        ]
        if self.folder_name_map_path:
            command.extend(["-FolderNameMapPath", self.folder_name_map_path])
        result = subprocess.run(
            command,
            cwd=str(BASE_DIR),
            text=True,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
        )
        if result.returncode == 0:
            self.finished_ok.emit(self.log_start_line)
            return
        message = (result.stderr or result.stdout or "PowerShell rename task failed.").strip()
        self.failed.emit(message)


class SettingsDialog(QDialog):
    def __init__(self, data, parent=None):
        super().__init__(parent)
        self.setWindowTitle("项目设置")
        self.resize(620, 260)
        self.data = deepcopy(data)
        self.current_project = self.data.get("current_project", "雷霆战机")

        layout = QVBoxLayout(self)
        form = QFormLayout()
        layout.addLayout(form)

        self.project_combo = QComboBox()
        self.project_combo.addItems(PROJECTS.keys())
        self.project_combo.setCurrentText(self.current_project)
        self.project_combo.currentTextChanged.connect(self.on_project_changed)
        form.addRow("项目", self.project_combo)

        self.image_dir = QLineEdit()
        self.video_dir = QLineEdit()
        form.addRow("图片输出文件夹", self.with_browse(self.image_dir))
        form.addRow("视频输出文件夹", self.with_browse(self.video_dir))

        self.image_seq = QSpinBox()
        self.image_seq.setRange(1, 999999)
        self.video_seq = QSpinBox()
        self.video_seq.setRange(1, 999999)
        form.addRow("图片起始编号", self.image_seq)
        form.addRow("视频起始编号", self.video_seq)

        buttons = QHBoxLayout()
        layout.addLayout(buttons)
        buttons.addStretch()
        save_button = QPushButton("保存")
        cancel_button = QPushButton("取消")
        save_button.clicked.connect(self.accept)
        cancel_button.clicked.connect(self.reject)
        buttons.addWidget(save_button)
        buttons.addWidget(cancel_button)

        self.load_project_to_ui(self.current_project)

    def with_browse(self, edit):
        wrapper = QWidget()
        layout = QHBoxLayout(wrapper)
        layout.setContentsMargins(0, 0, 0, 0)
        button = QPushButton("浏览")
        button.clicked.connect(lambda: self.choose_folder(edit))
        layout.addWidget(edit)
        layout.addWidget(button)
        return wrapper

    def choose_folder(self, edit):
        folder = QFileDialog.getExistingDirectory(self, "选择输出文件夹", edit.text() or str(BASE_DIR))
        if folder:
            edit.setText(normalize_folder(folder))

    def project_from_ui(self, name=None):
        if name is None:
            name = self.current_project
        return {
            "suffix": PROJECTS[name],
            "image_out_dir": normalize_folder(self.image_dir.text()),
            "video_out_dir": normalize_folder(self.video_dir.text()),
            "image_seq": self.image_seq.value(),
            "video_seq": self.video_seq.value(),
        }

    def save_current_project_from_ui(self):
        self.data["projects"][self.current_project] = self.project_from_ui(self.current_project)
        self.data["current_project"] = self.current_project

    def load_project_to_ui(self, name):
        project = self.data["projects"][name]
        self.image_dir.setText(project.get("image_out_dir", ""))
        self.video_dir.setText(project.get("video_out_dir", ""))
        self.image_seq.setValue(int(project.get("image_seq", 1)))
        self.video_seq.setValue(int(project.get("video_seq", 1)))

    def on_project_changed(self, name):
        self.save_current_project_from_ui()
        self.current_project = name
        self.data["current_project"] = name
        self.load_project_to_ui(name)

    def accept(self):
        self.save_current_project_from_ui()
        write_json(PROJECT_SETTINGS_PATH, self.data)
        super().accept()


class NineImageNameDialog(QDialog):
    def __init__(self, folders, parent=None):
        super().__init__(parent)
        self.setWindowTitle("9图名称确认")
        self.setWindowModality(Qt.ApplicationModal)
        self.setWindowFlag(Qt.WindowStaysOnTopHint, True)
        self.resize(560, 160 + min(len(folders), 6) * 42)
        self.folders = folders
        self.edits = {}

        layout = QVBoxLayout(self)
        intro = QLabel(f"检测到 {len(folders)} 个 9图作品，请确认命名基础名称。")
        layout.addWidget(intro)

        form = QFormLayout()
        layout.addLayout(form)
        for folder in folders:
            edit = QLineEdit(folder.name)
            self.edits[str(folder)] = edit
            form.addRow(folder.name, edit)

        buttons = QHBoxLayout()
        layout.addLayout(buttons)
        buttons.addStretch()
        ok_button = QPushButton("确定")
        cancel_button = QPushButton("取消")
        ok_button.clicked.connect(self.accept)
        cancel_button.clicked.connect(self.reject)
        buttons.addWidget(ok_button)
        buttons.addWidget(cancel_button)
        self.setStyleSheet(
            """
            QDialog {
                background: #242424;
                color: #f0f0f0;
            }
            QLabel {
                color: #f0f0f0;
            }
            QLineEdit {
                background: #333333;
                color: #f0f0f0;
                border: 1px solid #555555;
                border-radius: 4px;
                padding: 6px;
            }
            QPushButton {
                background: #3a3a3a;
                color: #f0f0f0;
                border: 1px solid #555555;
                border-radius: 4px;
                padding: 6px 14px;
            }
            QPushButton:hover {
                background: #454545;
            }
            """
        )

    def values(self):
        return {path: edit.text().strip() for path, edit in self.edits.items()}

    def accept(self):
        empty_names = [Path(path).name for path, value in self.values().items() if not value]
        if empty_names:
            QMessageBox.warning(self, "名称不能为空", "请填写所有 9图作品名称。")
            return
        super().accept()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("自动化命名")
        self.resize(680, 470)
        self.data = load_or_create_project_settings()
        self.worker = None
        self.active_project_name = None
        self.selected_project_name = self.data.get("current_project", "雷霆战机")
        self.folder_name_map_path = ""

        root = QWidget()
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)

        top_bar = QHBoxLayout()
        layout.addLayout(top_bar)
        top_bar.addStretch()
        self.settings_button = QPushButton("设置")
        self.settings_button.clicked.connect(self.open_settings)
        top_bar.addWidget(self.settings_button)

        project_row = QHBoxLayout()
        project_row.setSpacing(12)
        layout.addLayout(project_row)

        self.project_buttons = {}
        for name in PROJECTS:
            button = self.create_project_button(name)
            button.clicked.connect(lambda checked=False, project_name=name: self.start_rename(project_name))
            self.project_buttons[name] = button
            project_row.addWidget(button)

        self.status = QLabel("点击项目按钮开始命名。")
        layout.addWidget(self.status)

        layout.addWidget(QLabel("本次命名成功"))
        self.result_list = QListWidget()
        self.result_list.setFixedHeight(210)
        layout.addWidget(self.result_list)
        self.refresh_project_selection()
        self.refresh_work_count()

    def create_project_button(self, project_name):
        button = QToolButton()
        button.setText(project_name)
        button.setToolButtonStyle(Qt.ToolButtonTextUnderIcon)
        button.setIconSize(QSize(150, 112))
        button.setMinimumSize(300, 170)
        button.setCursor(Qt.PointingHandCursor)

        logo_path = available_logo_path(project_name)
        if logo_path:
            button.setIcon(QIcon(logo_path))

        button.setStyleSheet(
            """
            QToolButton {
                border: 1px solid #4a4a4a;
                border-radius: 6px;
                background: #353535;
                color: #f0f0f0;
                font-size: 14px;
                padding: 12px;
            }
            QToolButton:hover {
                background: #3f3f3f;
                border-color: #666666;
            }
            QToolButton:pressed {
                background: #2f2f2f;
            }
            QToolButton:disabled {
                color: #888888;
                background: #2b2b2b;
            }
            """
        )
        return button

    def refresh_project_selection(self):
        for project_name, button in self.project_buttons.items():
            selected = project_name == self.selected_project_name
            button.setProperty("selectedProject", selected)
            button.setStyleSheet(self.project_button_stylesheet(selected))
            button.style().unpolish(button)
            button.style().polish(button)

    def project_button_stylesheet(self, selected):
        if selected:
            background = "#1f6f43"
            hover = "#258350"
            border = "#39d27d"
        else:
            background = "#353535"
            hover = "#3f3f3f"
            border = "#4a4a4a"
        return f"""
            QToolButton {{
                border: 2px solid {border};
                border-radius: 6px;
                background: {background};
                color: #f4f4f4;
                font-size: 14px;
                padding: 12px;
            }}
            QToolButton:hover {{
                background: {hover};
                border-color: #66e09b;
            }}
            QToolButton:pressed {{
                background: #185934;
            }}
            QToolButton:disabled {{
                color: #888888;
                background: #2b2b2b;
                border-color: #3a3a3a;
            }}
            """

    def refresh_work_count(self):
        works, _ = scan_works()
        self.status.setText(f"检测到 {len(works)} 个作品。点击项目按钮开始命名。")

    def open_settings(self):
        dialog = SettingsDialog(self.data, self)
        if dialog.exec() == QDialog.Accepted:
            self.data = load_or_create_project_settings()
            self.selected_project_name = self.data.get("current_project", self.selected_project_name)
            self.refresh_project_selection()
            self.refresh_work_count()

    def start_rename(self, project_name):
        self.data = load_or_create_project_settings()
        project = self.data["projects"][project_name]
        if not project.get("image_out_dir") or not project.get("video_out_dir"):
            QMessageBox.warning(self, "配置不完整", "请先在设置中配置图片和视频输出文件夹。")
            return

        works, nine_folders = scan_works()
        self.result_list.clear()
        self.selected_project_name = project_name
        self.refresh_project_selection()
        self.active_project_name = project_name
        self.data["current_project"] = project_name
        write_json(PROJECT_SETTINGS_PATH, self.data)
        write_runtime_config(project)

        if nine_folders:
            dialog = NineImageNameDialog(nine_folders, self)
            dialog.show()
            dialog.raise_()
            dialog.activateWindow()
            if dialog.exec() != QDialog.Accepted:
                self.status.setText("已取消命名。")
                return
            handle = tempfile.NamedTemporaryFile(
                "w",
                delete=False,
                suffix=".json",
                encoding="utf-8-sig",
                dir=str(BASE_DIR),
            )
            with handle:
                json.dump(dialog.values(), handle, ensure_ascii=False, indent=4)
            self.folder_name_map_path = handle.name
        else:
            self.folder_name_map_path = ""

        log_start = log_line_count()
        self.set_running(True)
        self.status.setText(f"检测到 {len(works)} 个作品。正在执行：{project_name}")
        self.worker = RenameWorker(project["suffix"], log_start, self.folder_name_map_path)
        self.worker.finished_ok.connect(self.on_finished_ok)
        self.worker.failed.connect(self.on_failed)
        self.worker.start()

    def set_running(self, running):
        self.settings_button.setEnabled(not running)
        for button in self.project_buttons.values():
            button.setEnabled(not running)

    def on_finished_ok(self, log_start_line):
        sequence = read_json(SEQUENCE_PATH, {"image_seq": 1, "video_seq": 1})
        self.data = load_or_create_project_settings()
        project = self.data["projects"][self.active_project_name]
        project["image_seq"] = int(sequence.get("image_seq", project["image_seq"]))
        project["video_seq"] = int(sequence.get("video_seq", project["video_seq"]))
        self.data["projects"][self.active_project_name] = project
        self.data["current_project"] = self.active_project_name
        write_json(PROJECT_SETTINGS_PATH, self.data)

        rows = read_new_log_rows(log_start_line)
        for row in rows:
            new_name = row.get("NewName", "").strip()
            if not new_name:
                continue
            self.result_list.addItem(f"{new_name} | {detect_category(new_name)}")

        count = self.result_list.count()
        remaining_works, _ = scan_works()
        self.status.setText(f"{self.active_project_name} 执行完成，成功 {count} 个。当前检测到 {len(remaining_works)} 个作品。")
        self.set_running(False)
        self.cleanup_folder_name_map()
        QMessageBox.information(self, "完成", f"自动化命名已完成，成功 {count} 个。")

    def on_failed(self, message):
        self.set_running(False)
        self.cleanup_folder_name_map()
        self.refresh_work_count()
        self.status.setText("执行失败，请查看错误信息。")
        QMessageBox.critical(self, "执行失败", message)

    def cleanup_folder_name_map(self):
        if self.folder_name_map_path and Path(self.folder_name_map_path).exists():
            try:
                Path(self.folder_name_map_path).unlink()
            except OSError:
                pass
        self.folder_name_map_path = ""


def main():
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
