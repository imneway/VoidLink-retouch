//
//  LayoutOnScreenControlsViewController.h
//  Moonlight
//
//  Created by Long Le on 9/27/22.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//
//  Modified by True砖家 since 2024.6.24
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "LayoutOnScreenControls.h"
#import "ToolBarContainerView.h"
#import "OSCProfilesManager.h"
#import "OSCProfilesTableViewController.h"
#import "VoidLink-Swift.h"

NS_ASSUME_NONNULL_BEGIN

/**
 This view controller provides the user interface which allows the user to position on screen controller buttons anywhere they'd like on the screen. It also provides the user with the abilities to undo a change, save the on screen controller layout for later retrieval, and load previously saved controller layouts
 */
@interface LayoutOnScreenControlsViewController : UIViewController <OnScreenWidgetGuidelineUpdateDelegate>
- (void)profileRefresh;
- (void)reloadOnScreenWidgetViews;
- (void)presentProfilesTableView;
- (BOOL)isRotationLocked; // honored by the presenter's supportedInterfaceOrientations (OverCurrentContext)

@property LayoutOnScreenControls *layoutOSC;    // object that contains a view which contains the on screen controller buttons that allows the user to drag and positions each button on the screen using touch
@property (nonatomic) NSMutableSet* onScreenWidgetViews;

@property int OSCSegmentSelected;

@property (weak, nonatomic) IBOutlet UIButton *trashCanButton;
@property (weak, nonatomic) IBOutlet UIButton *undoButton;

@property (weak, nonatomic) IBOutlet ToolBarContainerView *toolbarRootView;
@property (weak, nonatomic) IBOutlet UIView *chevronView;
@property (weak, nonatomic) IBOutlet UIImageView *chevronImageView;
@property (weak, nonatomic) IBOutlet UIStackView *toolbarStackView;
@property (strong, nonatomic) OSCProfilesTableViewController *oscProfilesTableViewController;

@property (nonatomic, assign) NSString *currentProfileName;
@property (strong, nonatomic) IBOutlet UILabel *currentProfileLabel;

@property (weak, nonatomic) IBOutlet UILabel *widgetSizeLabel;
@property (weak, nonatomic) IBOutlet UISlider *widgetSizeSlider;
@property (weak, nonatomic) IBOutlet UIStackView *widgetSizeStack;

@property (weak, nonatomic) IBOutlet UILabel *widgetHeightLabel;
@property (weak, nonatomic) IBOutlet UISlider *widgetHeightSlider;

@property (weak, nonatomic) IBOutlet UIStackView *widgetHeightStack;

@property (weak, nonatomic) IBOutlet UILabel *widgetBorderWidthLabel;
@property (weak, nonatomic) IBOutlet UISlider *widgetBorderWidthSlider;
@property (weak, nonatomic) IBOutlet UILabel *widgetAlphaLabel;
@property (weak, nonatomic) IBOutlet UISlider *widgetAlphaSlider;
@property (weak, nonatomic) IBOutlet UIStackView *borderWidthAlphaStack;
@property (weak, nonatomic) IBOutlet UIButton *saveButton;
@property (weak, nonatomic) IBOutlet UIButton *exitButton;
@property (weak, nonatomic) IBOutlet UIButton *loadButton;
@property (weak, nonatomic) IBOutlet UIButton *addButton;
@property (weak, nonatomic) IBOutlet UIButton *editButton;




@property (weak, nonatomic) IBOutlet UILabel *stickIndicatorOffsetLabel;
@property (weak, nonatomic) IBOutlet UISlider *stickIndicatorOffsetSlider;
@property (weak, nonatomic) IBOutlet UIStackView *stickIndicatorOffsetStack;

@property (weak, nonatomic) IBOutlet UILabel *sensitivityXLabel;
@property (weak, nonatomic) IBOutlet UISlider *sensitivityXSlider;
@property (weak, nonatomic) IBOutlet UIStackView *sensitivityXStack;
@property (strong, nonatomic) IBOutlet UILabel *sensitivityYLabel;
@property (strong, nonatomic) IBOutlet UISlider *sensitivityYSlider;
@property (strong, nonatomic) IBOutlet UIStackView *sensitivityYStack;
@property (strong, nonatomic) UIStackView *sensitivityXYStack;
@property (strong, nonatomic) UILabel *aimSensitivityXLabel;
@property (strong, nonatomic) UISlider *aimSensitivityXSlider;
@property (strong, nonatomic) UIStackView *aimSensitivityXStack;
@property (strong, nonatomic) UILabel *aimSensitivityYLabel;
@property (strong, nonatomic) UISlider *aimSensitivityYSlider;
@property (strong, nonatomic) UIStackView *aimSensitivityYStack;
@property (strong, nonatomic) UIStackView *aimSensitivityXYStack;

@property (strong, nonatomic) IBOutlet UIStackView *decelerationRateStack;
@property (strong, nonatomic) IBOutlet UILabel *decelerationRateLabel;
@property (strong, nonatomic) IBOutlet UISlider *decelerationRateSlider;

// ALT-pad response curve controls (built programmatically, not in storyboard)
@property (strong, nonatomic) UILabel *stickInputScaleLabel;
@property (strong, nonatomic) UISlider *stickInputScaleSlider;
@property (strong, nonatomic) UIStackView *stickInputScaleStack;
@property (strong, nonatomic) UILabel *stickResponseExponentLabel;
@property (strong, nonatomic) UISlider *stickResponseExponentSlider;
@property (strong, nonatomic) UIStackView *stickResponseExponentStack;
@property (strong, nonatomic) UILabel *aimTrackpadGainLabel;
@property (strong, nonatomic) UISlider *aimTrackpadGainSlider;
@property (strong, nonatomic) UIStackView *aimTrackpadGainStack;
@property (strong, nonatomic) UILabel *aimDeadzoneLabel;
@property (strong, nonatomic) UISlider *aimDeadzoneSlider;
@property (strong, nonatomic) UIStackView *aimDeadzoneStack;
@property (strong, nonatomic) UILabel *aimMaxOutputLabel;
@property (strong, nonatomic) UISlider *aimMaxOutputSlider;
@property (strong, nonatomic) UIStackView *aimMaxOutputStack;
@property (strong, nonatomic) UILabel *aimResponseTimeLabel;
@property (strong, nonatomic) UISlider *aimResponseTimeSlider;
@property (strong, nonatomic) UIStackView *aimResponseTimeStack;
@property (strong, nonatomic) UILabel *aimAxisSnapLabel;
@property (strong, nonatomic) UISlider *aimAxisSnapSlider;
@property (strong, nonatomic) UIStackView *aimAxisSnapStack;
@property (strong, nonatomic) UILabel *aimRelativeModeLabel;
@property (strong, nonatomic) UIButton *aimRelativeModeButton;
@property (strong, nonatomic) UIStackView *aimRelativeModeStack;
@property (strong, nonatomic) UILabel *stickInvertVerticalLabel;
@property (strong, nonatomic) UISwitch *stickInvertVerticalSwitch;
@property (strong, nonatomic) UIStackView *stickInvertVerticalStack;
@property (strong, nonatomic) UILabel *stickInvertHorizontalLabel;
@property (strong, nonatomic) UISwitch *stickInvertHorizontalSwitch;
@property (strong, nonatomic) UIStackView *stickInvertHorizontalStack;
@property (strong, nonatomic) UIStackView *stickInvertAxisStack;
@property (strong, nonatomic) UILabel *doubleTapStickClickLabel;
@property (strong, nonatomic) UISwitch *doubleTapStickClickSwitch;
@property (strong, nonatomic) UIStackView *doubleTapStickClickStack;




@property (strong, nonatomic) IBOutlet UISegmentedControl *vibrationStyleSelector;
@property (strong, nonatomic) IBOutlet UIStackView *vibrationStyleStack;

@property (strong, nonatomic) IBOutlet UILabel *loadConfigTipLabel;

@property (strong, nonatomic) IBOutlet UIStackView *mouseDownButtonStack;
@property (strong, nonatomic) IBOutlet UISegmentedControl *mouseButtonDownSelector;

@property (strong, nonatomic) IBOutlet UIStackView *slidableStack;
@property (strong, nonatomic) IBOutlet UISegmentedControl *slidableSelector;



@property (weak, nonatomic) IBOutlet UIStackView *widgetPanelStack;

// 坐标显示和方向移动控件
@property (weak, nonatomic) IBOutlet UILabel *coordinateLabel;
@property (weak, nonatomic) IBOutlet UIButton *moveUpButton;
@property (weak, nonatomic) IBOutlet UIButton *moveDownButton;
@property (weak, nonatomic) IBOutlet UIButton *moveLeftButton;
@property (weak, nonatomic) IBOutlet UIButton *moveRightButton;
@property (weak, nonatomic) IBOutlet UIStackView *coordinateControlStack;

// 白色半透明 overlay，显示在串流画面之上，但在所有控件之下
@property (strong, nonatomic) UIView *streamOverlay;


@end


NS_ASSUME_NONNULL_END
