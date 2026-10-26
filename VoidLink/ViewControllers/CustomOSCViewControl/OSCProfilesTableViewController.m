//
//  OSCProfilesTableViewController.m
//  Moonlight
//
//  Created by Long Le on 11/28/22.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//
//  Modified by True砖家 since 2024.6.24
//  Copyright © 2024 True砖家 on Bilibili. All rights reserved.
//
//  Scene-based rewrite: three scene cards (portrait / landscape / full-screen game)
//  on top decide which layout the stream shows; the list below is a plain list of
//  layouts. Tapping a row opens it in the editor; swipe actions bind, copy, rename
//  and delete. There is no lock and no "selected" state in this UI any more.
//

#import "OSCProfilesTableViewController.h"
#import "LayoutOnScreenControlsViewController.h"
#import "ProfileTableViewCell.h"
#import "OSCProfile.h"
#import "OnScreenButtonState.h"
#import "OSCProfilesManager.h"
#import "OSCSceneManager.h"
#import "LocalizationHelper.h"

const double NAV_BAR_HEIGHT = 50;
static const CGFloat kSceneCardsHeight = 92.0;
static NSString * const kDefaultLayoutName = @"Default";

@interface OSCProfilesTableViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *sceneHeaderView;
@property (nonatomic, strong) NSArray<UIControl *> *sceneCards;
@end

@implementation OSCProfilesTableViewController {
    OSCProfilesManager *profilesManager;
}

#pragma mark - Orientation

- (UIInterfaceOrientationMask)getCurrentOrientation{
    CGFloat screenHeightInPoints = CGRectGetHeight([[UIScreen mainScreen] bounds]);
    CGFloat screenWidthInPoints = CGRectGetWidth([[UIScreen mainScreen] bounds]);
    if(screenWidthInPoints > screenHeightInPoints) return UIInterfaceOrientationMaskLandscape;
    else return UIInterfaceOrientationMaskPortrait|UIInterfaceOrientationMaskPortraitUpsideDown;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return [self getCurrentOrientation];
}

- (BOOL)osc_isCurrentLandscapeInViewBounds {
    return self.view.bounds.size.width > self.view.bounds.size.height;
}

#pragma mark - Lifecycle

- (void) viewDidDisappear:(BOOL)animated{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"OscLayoutTableViewCloseNotification" object:self]; // notify other view that oscLayoutManager is closing
    [super viewDidDisappear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"OSCProfilesOverlayRemove" object:nil];
}

- (void) viewDidLayoutSubviews {
    CGRect bounds = self.profileTableViewNavigationBar.bounds;
    CGSize cornerSize = CGSizeMake(15, 15);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds byRoundingCorners:(UIRectCornerTopLeft | UIRectCornerTopRight) cornerRadii:cornerSize];
    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    maskLayer.frame = bounds;
    maskLayer.path = path.CGPath;
    self.profileTableViewNavigationBar.layer.masksToBounds = true;
    self.profileTableViewNavigationBar.layer.mask = maskLayer;

    self.tableView.layer.cornerRadius = 15;
    self.tableView.layer.masksToBounds = true;

    if (self.systemBottomToolbar) {
        self.systemBottomToolbar.clipsToBounds = YES;
        self.systemBottomToolbar.layer.cornerRadius = 15;
        if ([self.systemBottomToolbar.layer respondsToSelector:@selector(setMaskedCorners:)]) {
            self.systemBottomToolbar.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        }
    }
    // Keep the header as wide as the table (tableHeaderView does not autoresize its width).
    if (self.sceneHeaderView && self.sceneHeaderView.bounds.size.width != self.tableView.bounds.size.width) {
        self.sceneHeaderView.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, NAV_BAR_HEIGHT + kSceneCardsHeight);
        self.tableView.tableHeaderView = self.sceneHeaderView;
    }
}

- (void) viewDidLoad {
    [super viewDidLoad];
    [OSCSceneManager migrateIfNeeded];
    profilesManager = [OSCProfilesManager sharedManager:_layoutViewBounds];

    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.tableView registerNib:[UINib nibWithNibName:@"ProfileTableViewCell" bundle:nil]
         forCellReuseIdentifier:@"Cell"];
    self.view.backgroundColor = [UIColor clearColor];
    self.tableView.alpha = 1.0;
    self.tableView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.95];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;

    if (self.navigationController) {
        self.navigationController.navigationBar.tintColor = [UIColor systemTealColor];
        self.navigationController.navigationBar.translucent = NO;
        self.navigationController.navigationBar.barTintColor = [UIColor whiteColor];
    }
    if (self.profileTableViewNavigationBar) {
        self.profileTableViewNavigationBar.tintColor = [UIColor systemTealColor];
        self.profileTableViewNavigationBar.translucent = NO;
        self.profileTableViewNavigationBar.barTintColor = [UIColor whiteColor];
        self.profileTableViewNavigationBar.topItem.title = [LocalizationHelper localizedStringForKey:@"Layouts"];
    }
    [self osc_removeLegacyNavItems];

    [self osc_buildSceneHeader];

    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBackgroundTap:)];
    bgTap.cancelsTouchesInView = NO;
    bgTap.delegate = self;
    [self.view addGestureRecognizer:bgTap];

    self.isProcessingOrientationChange = NO;

    if (self.systemBottomToolbar) {
        [self updateSystemToolbarItems];
    } else {
        [self setupBottomToolbar];
    }
    CGFloat tbHeight = self.systemBottomToolbar ? self.systemBottomToolbar.bounds.size.height : 50.0;
    CGFloat bottomInset = MAX(64.0, tbHeight + 30.0);
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, bottomInset, 0);
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, bottomInset, 0);

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceOrientationDidChange:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(osc_sceneBindingsChanged:)
                                                 name:OSCSceneBindingsDidChangeNotification
                                               object:nil];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear: animated];
    [self osc_reloadAll];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Duplicate / Delete used to act on the "selected" row; they live in swipe actions now.
- (void)osc_removeLegacyNavItems {
    UINavigationItem *item = self.profileTableViewNavigationBar.topItem;
    if (!item) return;
    NSMutableArray *keep = [NSMutableArray array];
    for (UIBarButtonItem *b in item.rightBarButtonItems) {
        if (b.action == @selector(duplicateTapped:) || b.action == @selector(deleteTapped:)) continue;
        [keep addObject:b];
    }
    item.rightBarButtonItems = keep;
    keep = [NSMutableArray array];
    for (UIBarButtonItem *b in item.leftBarButtonItems) {
        if (b.action == @selector(duplicateTapped:) || b.action == @selector(deleteTapped:)) continue;
        [keep addObject:b];
    }
    item.leftBarButtonItems = keep;
    [self osc_stripGlass:item.leftBarButtonItems];
    [self osc_stripGlass:item.rightBarButtonItems];
}

// iOS 26 puts a Liquid Glass capsule behind bar items; this sheet is flat.
- (void)osc_stripGlass:(NSArray<UIBarButtonItem *> *)items {
    for (UIBarButtonItem *b in items) {
        if (@available(iOS 26.0, *)) {
            b.hidesSharedBackground = YES;
            b.sharesBackground = NO;
        }
    }
}

#pragma mark - Data helpers

- (NSArray<NSString *> *)osc_allNames {
    NSMutableArray *names = [NSMutableArray array];
    for (OSCProfile *p in [profilesManager getAllProfiles]) if (p.name) [names addObject:p.name];
    return names;
}

- (OSCProfile *)osc_profileAtRow:(NSInteger)row {
    NSMutableArray *all = [profilesManager getAllProfiles];
    if (row < 0 || row >= all.count) return nil;
    return all[row];
}

- (void)osc_persistProfiles:(NSArray<OSCProfile *> *)profiles {
    NSMutableArray *profilesEncoded = [[NSMutableArray alloc] init];
    for (OSCProfile *profile in profiles) {
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:profile requiringSecureCoding:YES error:nil];
        if (d) [profilesEncoded addObject:d];
    }
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:profilesEncoded requiringSecureCoding:YES error:nil];
    if (!data) return;
    [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"OSCProfiles"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Deep copy through the archiver so button states are not shared with the source.
- (OSCProfile *)osc_cloneProfile:(OSCProfile *)source named:(NSString *)name {
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:source requiringSecureCoding:YES error:nil];
    NSSet *classes = [NSSet setWithObjects:[NSString class], [NSMutableData class], [NSMutableArray class], [OSCProfile class], [OnScreenButtonState class], nil];
    OSCProfile *copy = d ? [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:d error:nil] : nil;
    if (!copy) return nil;
    copy.name = name;
    copy.isSelected = NO;
    return copy;
}

- (void)osc_reloadAll {
    [self osc_refreshSceneCards];
    [self.tableView reloadData];
    [self updateToolbarButtons];
}

- (void)osc_sceneBindingsChanged:(NSNotification *)note {
    [self osc_reloadAll];
}

- (void)osc_presentMessage:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Scene cards

- (void)osc_buildSceneHeader {
    // The navigation bar sits over the top NAV_BAR_HEIGHT points of the table.
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MAX(self.tableView.bounds.size.width, 300), NAV_BAR_HEIGHT + kSceneCardsHeight)];
    header.backgroundColor = [UIColor clearColor];

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 10;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [row.topAnchor constraintEqualToAnchor:header.topAnchor constant:NAV_BAR_HEIGHT + 14],
        [row.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10],
    ]];

    NSMutableArray *cards = [NSMutableArray array];
    for (NSInteger s = 0; s < OSCSceneCount; s++) {
        UIControl *card = [[UIControl alloc] init];
        card.tag = s;
        card.layer.cornerRadius = 12;
        card.clipsToBounds = YES;
        [card addTarget:self action:@selector(osc_sceneCardTapped:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *title = [[UILabel alloc] init];
        title.tag = 1001;   // card.tag is the scene index, keep label tags out of that range
        title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        title.textColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.text = [OSCSceneManager localizedNameForScene:(OSCScene)s];
        [card addSubview:title];

        UILabel *value = [[UILabel alloc] init];
        value.tag = 1002;
        value.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        value.textColor = [UIColor blackColor];
        value.numberOfLines = 2;
        value.adjustsFontSizeToFitWidth = YES;
        value.minimumScaleFactor = 0.7;
        value.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:value];

        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
            [value.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [value.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
            [value.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
            [value.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-8],
        ]];
        [row addArrangedSubview:card];
        [cards addObject:card];
    }
    self.sceneCards = cards;
    self.sceneHeaderView = header;
    self.tableView.tableHeaderView = header;
    [self osc_refreshSceneCards];
}

- (OSCScene)osc_sceneForCurrentOrientation {
    return [self osc_isCurrentLandscapeInViewBounds] ? OSCSceneLandscape : OSCScenePortrait;
}

- (void)osc_refreshSceneCards {
    NSArray<NSString *> *names = [self osc_allNames];
    OSCScene nowScene = [self osc_sceneForCurrentOrientation];
    UIColor *teal = [UIColor systemTealColor];
    for (UIControl *card in self.sceneCards) {
        OSCScene scene = (OSCScene)card.tag;
        UILabel *value = [card viewWithTag:1002];
        NSString *bound = [OSCSceneManager boundProfileNameForScene:scene];
        NSString *resolved = [OSCSceneManager resolvedProfileNameForScene:scene existingNames:names];
        BOOL dangling = bound.length > 0 && ![names containsObject:bound];
        if (scene == OSCSceneLandscapeFullGame && bound.length == 0) {
            value.text = [LocalizationHelper localizedStringForKey:@"Same as landscape"];
            value.textColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
        } else if (dangling) {
            value.text = [NSString stringWithFormat:@"%@ → %@", bound, resolved];
            value.textColor = [UIColor systemOrangeColor];
        } else {
            value.text = resolved;
            value.textColor = bound.length > 0 ? [UIColor blackColor] : [[UIColor blackColor] colorWithAlphaComponent:0.45];
        }
        BOOL current = (scene == nowScene) || (scene == OSCSceneLandscapeFullGame && nowScene == OSCSceneLandscape);
        card.backgroundColor = current ? [teal colorWithAlphaComponent:0.14] : [[UIColor blackColor] colorWithAlphaComponent:0.05];
    }
}

- (void)osc_sceneCardTapped:(UIControl *)card {
    OSCScene scene = (OSCScene)card.tag;
    NSString *bound = [OSCSceneManager boundProfileNameForScene:scene];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[OSCSceneManager localizedNameForScene:scene]
                                                                   message:[LocalizationHelper localizedStringForKey:@"Pick the layout this scene shows"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (scene == OSCSceneLandscapeFullGame) {
        NSString *t = [LocalizationHelper localizedStringForKey:@"Same as landscape"];
        if (bound.length == 0) t = [@"✓ " stringByAppendingString:t];
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [OSCSceneManager bindProfileName:nil toScene:scene];
        }]];
    }
    for (OSCProfile *p in [profilesManager getAllProfiles]) {
        if (!p.name) continue;
        NSString *t = p.name;
        BOOL isBound = bound && [bound isEqualToString:p.name];
        BOOL isImplicitDefault = (bound.length == 0 && scene != OSCSceneLandscapeFullGame && [p.name isEqualToString:kDefaultLayoutName]);
        if (isBound || isImplicitDefault) t = [@"✓ " stringByAppendingString:t];
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [OSCSceneManager bindProfileName:p.name toScene:scene];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = card;
        pop.sourceRect = card.bounds;
        pop.permittedArrowDirections = UIPopoverArrowDirectionUp | UIPopoverArrowDirectionDown;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Row actions

// Open the layout in the editor: make it the edited layout, refresh the editor, dismiss.
- (void)osc_openProfileInEditor:(OSCProfile *)profile {
    if (!profile.name) return;
    if (![[[profilesManager getSelectedProfile] name] isEqualToString:profile.name]) {
        [profilesManager setProfileToSelected:profile.name];
        [self profileViewRefresh];
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)osc_promptCopyProfile:(OSCProfile *)source {
    NSString *title = [LocalizationHelper localizedStringForKey:@"Copy layout"];
    UIAlertController *input = [UIAlertController alertControllerWithTitle:title
                                                                   message:[LocalizationHelper localizedStringForKey:@"Enter the name you want to save this profile as"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [input addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"name"];
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.text = [self osc_suggestedCopyNameFor:source.name];
    }];
    __weak UIAlertController *weakInput = input;   // the alert owns the action; don't let the handler own the alert
    [input addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [input addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Save"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [weakInput.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *problem = [self osc_validateNewName:name];
        if (problem) { [self osc_presentMessage:problem]; return; }
        NSMutableArray *all = [self->profilesManager getAllProfiles];
        OSCProfile *copy = [self osc_cloneProfile:source named:name];
        if (!copy) { [self osc_presentMessage:[LocalizationHelper localizedStringForKey:@"Failed to copy layout"]]; return; }
        [all addObject:copy];
        [self osc_persistProfiles:all];
        [self osc_reloadAll];
        // A copy of a template is the way to start editing one: open it right away.
        if ([self->profilesManager isTemplateProfile:source.name]) {
            [self osc_openProfileInEditor:copy];
        }
    }]];
    [self presentViewController:input animated:YES completion:nil];
}

- (NSString *)osc_suggestedCopyNameFor:(NSString *)base {
    NSString *stem = base ?: @"Layout";
    if ([stem rangeOfString:@" / "].location != NSNotFound) {
        stem = [[stem componentsSeparatedByString:@" / "] firstObject];   // bilingual template names
    }
    NSArray *names = [self osc_allNames];
    NSString *candidate = [NSString stringWithFormat:@"%@ 2", stem];
    NSInteger n = 2;
    while ([names containsObject:candidate]) {
        n++;
        candidate = [NSString stringWithFormat:@"%@ %ld", stem, (long)n];
    }
    return candidate;
}

- (NSString *)osc_validateNewName:(NSString *)name {
    if (name.length == 0) return [LocalizationHelper localizedStringForKey:@"Profile name cannot be blank!"];
    if ([profilesManager isTemplateProfile:name]) return [LocalizationHelper localizedStringForKey:@"Template names are reserved"];
    if ([profilesManager profileNameAlreadyExist:name]) return [LocalizationHelper localizedStringForKey:@"Profile name already exists"];
    return nil;
}

- (void)osc_promptRenameProfile:(OSCProfile *)profile {
    UIAlertController *input = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@"Rename layout"]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [input addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = profile.name;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakInput = input;
    [input addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [input addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Save"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [weakInput.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([name isEqualToString:profile.name]) return;
        NSString *problem = [self osc_validateNewName:name];
        if (problem) { [self osc_presentMessage:problem]; return; }
        NSMutableArray *all = [self->profilesManager getAllProfiles];
        OSCProfile *target = [self->profilesManager findProfileByName:profile.name inProfileArray:all];
        if (!target) return;
        NSString *oldName = target.name;
        target.name = name;
        [self osc_persistProfiles:all];
        [OSCSceneManager noteProfileRenamedFrom:oldName to:name];
        [self osc_reloadAll];
        if (self.needToUpdateOscLayoutTVC) self.needToUpdateOscLayoutTVC();   // editor label shows the name
    }]];
    [self presentViewController:input animated:YES completion:nil];
}

- (void)osc_confirmDeleteProfile:(OSCProfile *)profile {
    if ([profilesManager isTemplateProfile:profile.name]) {
        [self osc_presentMessage:[LocalizationHelper localizedStringForKey:@"DeleteTemplateNotAllowed:%@", profile.name]];
        return;
    }
    NSArray<NSNumber *> *scenes = [OSCSceneManager scenesBoundToProfileName:profile.name];
    NSString *message = [LocalizationHelper localizedStringForKey:@"ConfirmDeleteProfile:%@", profile.name];
    if (scenes.count > 0) {
        NSMutableArray *sceneNames = [NSMutableArray array];
        for (NSNumber *s in scenes) [sceneNames addObject:[OSCSceneManager localizedNameForScene:(OSCScene)s.integerValue]];
        message = [message stringByAppendingFormat:@"\n\n%@", [LocalizationHelper localizedStringForKey:@"Scenes using it fall back to Default: %@", [sceneNames componentsJoinedByString:@", "]]];
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@"ConfirmDelete"] message:message preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self osc_deleteProfile:profile];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)osc_deleteProfile:(OSCProfile *)profile {
    NSMutableArray *all = [profilesManager getAllProfiles];
    OSCProfile *target = [profilesManager findProfileByName:profile.name inProfileArray:all];
    if (!target) return;
    BOOL wasEdited = target.isSelected;
    [all removeObject:target];
    if (wasEdited) {
        // The editor was on this layout: fall back to Default (or whatever is left).
        OSCProfile *fallback = [profilesManager findProfileByName:kDefaultLayoutName inProfileArray:all] ?: all.firstObject;
        for (OSCProfile *p in all) p.isSelected = (p == fallback);
    }
    [self osc_persistProfiles:all];
    [OSCSceneManager noteProfileDeleted:profile.name];
    [self osc_reloadAll];
    if (wasEdited) [self profileViewRefresh];
}

- (void)osc_toggleProfile:(OSCProfile *)profile forScene:(OSCScene)scene {
    NSString *bound = [OSCSceneManager boundProfileNameForScene:scene];
    if (bound && [bound isEqualToString:profile.name]) {
        [OSCSceneManager bindProfileName:nil toScene:scene];      // back to Default / same as landscape
    } else {
        [OSCSceneManager bindProfileName:profile.name toScene:scene];
    }
}

#pragma mark - Legacy IBActions (kept for storyboard wiring)

- (IBAction) duplicateTapped:(id)sender {
    OSCProfile *current = [profilesManager getSelectedProfile];
    if (current) [self osc_promptCopyProfile:current];
}

- (IBAction) deleteTapped:(id)sender {
    OSCProfile *current = [profilesManager getSelectedProfile];
    if (current) [self osc_confirmDeleteProfile:current];
}

/* Refresh this list and tell the editor to reload the edited layout from storage. */
- (void) profileViewRefresh{
    [self osc_reloadAll];
    if (self.needToUpdateOscLayoutTVC) {
        self.needToUpdateOscLayoutTVC();
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"OscLayoutProfileSelctedInTableView" object:self];
}

- (IBAction) exportDataTapped:(id)sender {
    self.currentFileOperation = Export;
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"profiles.bin"];
    [[NSData new] writeToFile:tempPath atomically:YES];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithURL:[NSURL fileURLWithPath:tempPath] inMode:UIDocumentPickerModeExportToService];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (IBAction) importDataTapped:(id)sender {
    self.currentFileOperation = Import;
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item"] inMode:UIDocumentPickerModeOpen];
    documentPicker.delegate = self;
    documentPicker.allowsMultipleSelection = NO;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

- (IBAction) exitTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL* url = urls.firstObject;
    if (!url) return;
    switch(self.currentFileOperation){
        case Export:
            [self profilesToFile:url];break;
        case Import:
            [self fileToProfiles:url];break;
        default:break;
    }
}

- (void)profilesToFile:(NSURL* )destinationURL{
    NSError *error;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:[profilesManager getEncodedProfiles] requiringSecureCoding:YES error:&error];
    if (!data) {
        NSLog(@"序列化失败: %@", error);
        return;
    }
    [destinationURL startAccessingSecurityScopedResource];
    BOOL success = [data writeToURL:destinationURL options:NSDataWritingAtomic error:&error];
    [destinationURL stopAccessingSecurityScopedResource];
    if (!success) {
        NSLog(@"写入失败: %@", error);
    }
}

- (void)fileToProfiles:(NSURL* )sourceURL{
    bool restoreFailed = false;
    if (![sourceURL startAccessingSecurityScopedResource]) {
        restoreFailed = true;
    }
    NSError* error;
    NSData* fileData = [NSData dataWithContentsOfURL:sourceURL options:0 error:&error];
    [sourceURL stopAccessingSecurityScopedResource];
    if (!fileData) {
        restoreFailed = true;
    }
    NSSet *classes = [NSSet setWithObjects: [NSMutableData class], [NSMutableArray class], nil];
    NSMutableArray *profilesEncoded = nil;
    if (!restoreFailed) {
        error = nil;
        profilesEncoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:fileData error:&error];
        restoreFailed = (error != nil) || profilesEncoded == nil;
    }

    UIAlertAction *okAction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"OK"] style:UIAlertActionStyleDefault handler:nil];
    if(restoreFailed){
        UIAlertController *failed = [UIAlertController alertControllerWithTitle:@"" message:[LocalizationHelper localizedStringForKey:@"Failed to import profiles"] preferredStyle:UIAlertControllerStyleAlert];
        [failed addAction:okAction];
        [self presentViewController:failed animated:YES completion:nil];
    }
    else{
        [profilesManager importEncodedProfiles:profilesEncoded];
        UIAlertController *restored = [UIAlertController alertControllerWithTitle:@"" message:[LocalizationHelper localizedStringForKey:@"Pofiles imported"] preferredStyle:UIAlertControllerStyleAlert];
        [restored addAction:okAction];
        [self presentViewController:restored animated:YES completion:nil];
    }
    [self profileViewRefresh];
}

#pragma mark - TableView DataSource

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [[profilesManager getAllProfiles] count];
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ProfileTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    OSCProfile *profile = [self osc_profileAtRow:indexPath.row];
    if (profile == nil) {
        cell.name.text = @"—";
        return cell;
    }
    NSString *baseName = profile.name ?: @"未命名配置";
    BOOL isTemplate = [profilesManager isTemplateProfile:profile.name];

    UIFont *nameFont = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:baseName attributes:@{NSFontAttributeName:nameFont, NSForegroundColorAttributeName:[UIColor blackColor]}];

    // Scene badges: which scenes show this layout.
    for (NSNumber *s in [OSCSceneManager scenesBoundToProfileName:profile.name]) {
        OSCScene scene = (OSCScene)s.integerValue;
        UIColor *color = scene == OSCSceneLandscapeFullGame ? [UIColor systemOrangeColor] : [UIColor systemTealColor];
        [line appendAttributedString:[self osc_pillAttachment:[OSCSceneManager shortLocalizedNameForScene:scene] color:color]];
    }
    if (isTemplate) {
        [line appendAttributedString:[self osc_pillAttachment:[LocalizationHelper localizedStringForKey:@"Template"] color:[[UIColor blackColor] colorWithAlphaComponent:0.45]]];
    }

    cell.name.attributedText = line;
    cell.name.backgroundColor = [UIColor clearColor];
    cell.name.alpha = 1.0;
    cell.name.shadowColor = nil;
    cell.name.shadowOffset = CGSizeZero;
    cell.contentView.alpha = 1.0;
    cell.userInteractionEnabled = YES;

    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.tintColor = [[UIColor blackColor] colorWithAlphaComponent:0.3];

    UIView *existingSeparator = [cell viewWithTag:100];
    if (existingSeparator) [existingSeparator removeFromSuperview];
    CGFloat separatorHeight = 1.0;
    UIView *separatorView = [[UIView alloc] initWithFrame:CGRectMake(0, cell.bounds.size.height - separatorHeight, cell.bounds.size.width, separatorHeight)];
    separatorView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.12];
    separatorView.tag = 100;
    separatorView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [cell addSubview:separatorView];
    separatorView.layer.zPosition = 1;
    return cell;
}

- (NSAttributedString *)osc_pillAttachment:(NSString *)text color:(UIColor *)color {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:@" " attributes:@{NSKernAttributeName:@(4)}];
    UIImage *pill = [self osc_makePill:text color:color];
    NSTextAttachment *att = [[NSTextAttachment alloc] init];
    att.image = pill;
    att.bounds = CGRectMake(0, -3, pill.size.width, pill.size.height);
    [out appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
    return out;
}

- (BOOL) tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self osc_profileAtRow:indexPath.row] != nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 60.0;
}

// Leading swipe: scene bindings for this layout.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    OSCProfile *profile = [self osc_profileAtRow:indexPath.row];
    if (!profile) return nil;
    NSMutableArray *actions = [NSMutableArray array];
    OSCScene order[3] = { OSCSceneLandscapeFullGame, OSCSceneLandscape, OSCScenePortrait };
    for (int i = 0; i < 3; i++) {
        OSCScene scene = order[i];
        NSString *bound = [OSCSceneManager boundProfileNameForScene:scene];
        BOOL isBound = bound && [bound isEqualToString:profile.name];
        NSString *title = isBound
            ? [LocalizationHelper localizedStringForKey:@"Unbind %@", [OSCSceneManager shortLocalizedNameForScene:scene]]
            : [LocalizationHelper localizedStringForKey:@"Use for %@", [OSCSceneManager shortLocalizedNameForScene:scene]];
        UIContextualAction *a = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:title handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self osc_toggleProfile:profile forScene:scene];
            completionHandler(YES);
        }];
        if (isBound) a.backgroundColor = [UIColor systemGrayColor];
        else a.backgroundColor = scene == OSCSceneLandscapeFullGame ? [UIColor systemOrangeColor] : [UIColor systemTealColor];
        [actions addObject:a];
    }
    UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:actions];
    cfg.performsFirstActionWithFullSwipe = NO;
    return cfg;
}

// Trailing swipe: copy / rename / delete.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    OSCProfile *profile = [self osc_profileAtRow:indexPath.row];
    if (!profile) return nil;
    BOOL isTemplate = [profilesManager isTemplateProfile:profile.name];
    NSMutableArray *actions = [NSMutableArray array];
    if (!isTemplate) {
        UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:[LocalizationHelper localizedStringForKey:@"Delete"] handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self osc_confirmDeleteProfile:profile];
            completionHandler(YES);
        }];
        [actions addObject:del];
        UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:[LocalizationHelper localizedStringForKey:@"Rename"] handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self osc_promptRenameProfile:profile];
            completionHandler(YES);
        }];
        rename.backgroundColor = [UIColor systemIndigoColor];
        [actions addObject:rename];
    }
    UIContextualAction *copy = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:[LocalizationHelper localizedStringForKey:@"Copy"] handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self osc_promptCopyProfile:profile];
        completionHandler(YES);
    }];
    copy.backgroundColor = [UIColor systemBlueColor];
    [actions addObject:copy];
    UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:actions];
    cfg.performsFirstActionWithFullSwipe = NO;
    return cfg;
}

#pragma mark - TableView Delegate

/* Tap a row: open that layout in the editor. Templates cannot be edited, offer a copy. */
- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    OSCProfile *profile = [self osc_profileAtRow:indexPath.row];
    if (!profile) return;
    if ([profilesManager isTemplateProfile:profile.name]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:profile.name
                                                                   message:[LocalizationHelper localizedStringForKey:@"Templates cannot be edited. Copy it to a new layout to edit, or assign it to a scene with a swipe."]
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Copy and edit"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self osc_promptCopyProfile:profile];
        }]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self osc_openProfileInEditor:profile];
}

#pragma mark - Toolbar Management

- (void)setupBottomToolbar {
    if (!self.bottomToolbarView) {
        self.bottomToolbarView = [[UIView alloc] init];
        self.bottomToolbarView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.8];
        self.bottomToolbarView.layer.cornerRadius = 8;
        self.bottomToolbarView.layer.masksToBounds = YES;
        self.bottomToolbarView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.bottomToolbarView];
        [NSLayoutConstraint activateConstraints:@[
            [self.bottomToolbarView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
            [self.bottomToolbarView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
            [self.bottomToolbarView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
            [self.bottomToolbarView.heightAnchor constraintEqualToConstant:50],
        ]];
        [self.view bringSubviewToFront:self.bottomToolbarView];
    }
    [self updateToolbarButtons];
}

- (void)updateToolbarButtons {
    if (self.systemBottomToolbar) {
        [self updateSystemToolbarItems];
        return;
    }
    if (!self.bottomToolbarView) return;
    for (UIView *subview in self.bottomToolbarView.subviews) [subview removeFromSuperview];
    [self createNormalModeButtonWithTitle:[LocalizationHelper localizedStringForKey:@"How scenes work"] action:@selector(helpToolbarTapped:)];
}

#pragma mark - System UIToolbar Support

- (void)updateSystemToolbarItems {
    if (!self.systemBottomToolbar) return;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UILabel *hintLabel = [[UILabel alloc] init];
    hintLabel.text = [LocalizationHelper localizedStringForKey:@"Tap a layout to edit it · swipe for more"];
    hintLabel.font = [UIFont systemFontOfSize:14];
    hintLabel.textColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
    [hintLabel sizeToFit];
    UIBarButtonItem *hint = [[UIBarButtonItem alloc] initWithCustomView:hintLabel];   // a plain label: no glass capsule
    [self osc_stripGlass:@[hint]];
    if (self.helpToolbarItem) {
        if (@available(iOS 13.0, *)) {
            self.helpToolbarItem.image = [UIImage systemImageNamed:@"questionmark.circle"];
        }
        self.helpToolbarItem.title = nil;
        self.helpToolbarItem.target = self;
        self.helpToolbarItem.action = @selector(helpToolbarTapped:);
        self.helpToolbarItem.enabled = YES;
        [self osc_stripGlass:@[self.helpToolbarItem]];
        [self.systemBottomToolbar setItems:@[hint, flex, self.helpToolbarItem] animated:NO];
    } else {
        [self.systemBottomToolbar setItems:@[hint, flex] animated:NO];
    }
}

- (IBAction)pairRotationalToolbarTapped:(id)sender {
    [self helpToolbarTapped:sender];
}

- (IBAction)helpToolbarTapped:(id)sender {
    NSString *title = [LocalizationHelper localizedStringForKey:@"Scenes"];
    NSString *message = [LocalizationHelper localizedStringForKey:@"ScenesHelpMessage"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"OK"] style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createNormalModeButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *mainButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [mainButton setTitle:title forState:UIControlStateNormal];
    [mainButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [mainButton addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    mainButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bottomToolbarView addSubview:mainButton];
    [NSLayoutConstraint activateConstraints:@[
        [mainButton.centerXAnchor constraintEqualToAnchor:self.bottomToolbarView.centerXAnchor],
        [mainButton.centerYAnchor constraintEqualToAnchor:self.bottomToolbarView.centerYAnchor]
    ]];
}

- (void)deviceOrientationDidChange:(NSNotification *)notification {
    if (self.isProcessingOrientationChange) return;
    self.isProcessingOrientationChange = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self osc_reloadAll];   // the highlighted "current" scene card follows the orientation
        self.isProcessingOrientationChange = NO;
    });
}

#pragma mark - Gestures

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self.view];
    if (CGRectContainsPoint(self.tableView.frame, p)) return NO;
    if (self.systemBottomToolbar && CGRectContainsPoint(self.systemBottomToolbar.frame, p)) return NO;
    if (CGRectContainsPoint(self.profileTableViewNavigationBar.frame, p)) return NO;
    return YES;
}

- (void)handleBackgroundTap:(UITapGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateEnded) {
        [self dismissViewControllerAnimated:YES completion:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"OSCProfilesOverlayRemove" object:nil];
    }
}

#pragma mark - Drawing

- (UIImage *)osc_makePill:(NSString *)text color:(UIColor *)color {
    const CGFloat pillHeight = 18.0;
    const CGFloat cornerRadius = 4.0;
    const CGFloat horizontalPadding = 5.0;
    UIFont *font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color };
    CGSize textSize = [text sizeWithAttributes:attrs];
    CGSize canvas = CGSizeMake(ceil(textSize.width) + horizontalPadding * 2.0, pillHeight);
    UIGraphicsBeginImageContextWithOptions(canvas, NO, 0);
    if (UIGraphicsGetCurrentContext()) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, canvas.width, canvas.height) cornerRadius:cornerRadius];
        [[color colorWithAlphaComponent:0.14] setFill];
        [path fill];
        [text drawAtPoint:CGPointMake(horizontalPadding, floor((pillHeight - textSize.height) * 0.5)) withAttributes:attrs];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@end
