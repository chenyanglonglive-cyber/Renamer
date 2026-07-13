import csv
import json
import os
import subprocess
import sys
from copy import deepcopy
from pathlib import Path

from PySide6.QtCore import QThread, Signal
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
    QVBoxLayout,
    QWidget,
)


BASE_DIR = Path(__file__).resolve().parent
SETTINGS_PATH = BASE_DIR / "settings.json"
SEQUENCE_PATH = BASE_DIR / "sequence.json"
PROJECT_SETTINGS_PATH = BASE_DIR / "project_settings.json"
RENAME_SCRIPT_PATH = BASE_DIR / "rename_logic.ps1"
LOG_PATH = BASE_DIR / "naming_log.csv"

PROJECTS = {
    "雷霆战机": "雷霆",
    "英雄请出战": "英雄",
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


class RenameWorker(QThread):
    finished_ok = Signal(int)
    failed = Signal(str)

    def __init__(self, suffix, log_start_line):
        super().__init__()
        self.suffix = suffix
        self.log_start_line = log_start_line

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


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("自动化命名")
        self.resize(620, 430)
        self.data = load_or_create_project_settings()
        self.worker = None
        self.active_project_name = None

        root = QWidget()
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)

        top_bar = QHBoxLayout()
        layout.addLayout(top_bar)
        top_bar.addStretch()
        self.settings_button = QPushButton("设置")
        self.settings_button.clicked.connect(self.open_settings)
        top_bar.addWidget(self.settings_button)

        self.project_buttons = {}
        for name in PROJECTS:
            button = QPushButton(name)
            button.setMinimumHeight(76)
            button.clicked.connect(lambda checked=False, project_name=name: self.start_rename(project_name))
            self.project_buttons[name] = button
            layout.addWidget(button)

        self.status = QLabel("点击项目按钮开始命名。")
        layout.addWidget(self.status)

        layout.addWidget(QLabel("本次命名成功"))
        self.result_list = QListWidget()
        self.result_list.setFixedHeight(210)
        layout.addWidget(self.result_list)

    def open_settings(self):
        dialog = SettingsDialog(self.data, self)
        if dialog.exec() == QDialog.Accepted:
            self.data = load_or_create_project_settings()
            self.status.setText("设置已保存。")

    def start_rename(self, project_name):
        self.data = load_or_create_project_settings()
        project = self.data["projects"][project_name]
        if not project.get("image_out_dir") or not project.get("video_out_dir"):
            QMessageBox.warning(self, "配置不完整", "请先在设置中配置图片和视频输出文件夹。")
            return

        self.result_list.clear()
        self.active_project_name = project_name
        self.data["current_project"] = project_name
        write_json(PROJECT_SETTINGS_PATH, self.data)
        write_runtime_config(project)

        log_start = log_line_count()
        self.set_running(True)
        self.status.setText(f"正在执行：{project_name}")
        self.worker = RenameWorker(project["suffix"], log_start)
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
        self.status.setText(f"{self.active_project_name} 执行完成，成功 {count} 个。")
        self.set_running(False)
        QMessageBox.information(self, "完成", f"自动化命名已完成，成功 {count} 个。")

    def on_failed(self, message):
        self.set_running(False)
        self.status.setText("执行失败，请查看错误信息。")
        QMessageBox.critical(self, "执行失败", message)


def main():
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
