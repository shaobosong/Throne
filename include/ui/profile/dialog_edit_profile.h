#pragma once
#include <QDialog>
#include "profile_editor.h"

class QTabWidget;

#include "include/ui/utils/FloatCheckBox.h"
#include "ui_dialog_edit_profile.h"
#include "include/database/entities/Profile.h"

namespace Ui {
    class DialogEditProfile;
}

class DialogEditProfile : public QDialog {
    Q_OBJECT

public:
    explicit DialogEditProfile(const QString &_type, int profileOrGroupId, QWidget *parent = nullptr);

    ~DialogEditProfile() override;

    void toggleSingboxWidgets(bool show);

    void toggleXrayWidgets(bool show);

    // Show or hide the sing-box detail pane (right_all_w) based on
    // whether any of its child boxes (security_box, network_box,
    // tls_camouflage_box) are currently visible.
    void syncRightPanelVisibility();

    void setupSinglePanelLayout();

    void syncTabVisibility();

public slots:

    void accept() override;

private slots:
    void on_certificate_edit_clicked();
    void on_xray_downloadsettings_edit_clicked();
private:
    Ui::DialogEditProfile *ui;

    std::map<QWidget *, FloatCheckBox *> apply_to_group_ui;

    QWidget *innerWidget{};
    ProfileEditor *innerEditor{};

    QString type;
    int groupId;
    bool newEnt = false;
    // Once the dialog has been shown once (either via the initial
    // adjustPosition(mainwindow) centering or by any later move()),
    // we must NOT re-center it again. Subsequent asynchronous
    // ADJUST_SIZE invocations triggered by nested setCurrentText()
    // signals (e.g. security/network/xray_security) would otherwise
    // yank the window back over the mainwindow and the user would
    // see it "jump" while switching proxy types.
    bool positioned = false;
    std::shared_ptr<Configs::Profile> ent;

    QString network_title_base;

    QTabWidget *panelTabs{};
    int basicTabIndex = -1;
    int protocolTabIndex = -1;
    int detailTabIndex = -1;

    struct {
        QStringList certificate;
        QString XrayDownloadSettings;
    } CACHE;

    void typeSelected(const QString &newType);

    void updateXrayCommons(QString network);

    bool validateHeaders();

    bool onEnd();

    void requestAdjustSize();

    void editor_cache_updated_impl();

    bool suspendAdjustSize = false;
    int adjustSizeRequestId = 0;
};
