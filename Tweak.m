#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>

#pragma mark - RainyDay runtime declarations

@interface RDSong : NSObject
@property (nonatomic, copy) NSString *sid;
@property (nonatomic, copy) NSString *yid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy) NSString *picId;
@property (nonatomic, copy) NSString *lyricId;
@property (nonatomic, copy) NSString *urlId;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSString *picURL;
- (NSDictionary *)dictionary;
+ (instancetype)songFromDictionary:(NSDictionary *)dictionary;
@end

@interface RDPlayer : NSObject
+ (instancetype)shared;
@property (nonatomic, strong) NSArray *queue;
@property (nonatomic, strong) RDSong *currentSong;
- (void)playSong:(RDSong *)song inQueue:(NSArray *)queue;
- (void)itemDidFinishPlaying:(NSNotification *)notification;
@end

@interface RDCache : NSObject
+ (instancetype)shared;
@property (nonatomic, copy) NSString *root;
@property (nonatomic, copy) NSString *coverDir;
@property (nonatomic, copy) NSString *songDir;
@property (nonatomic, copy) NSString *lyricDir;
@property (nonatomic, copy) NSString *offlineDir;
- (NSArray *)offlineSongs;
- (void)removeOfflineSong:(id)song;
@end

@interface RDMainViewController : UIViewController
@end

@interface RDMainViewController (EnhancerUI)
- (void)rd_viewDidAppear:(BOOL)animated;
- (void)rd_installToolsButton;
- (void)rd_openTools:(id)sender;
@end

#pragma mark - Helpers

static NSString *RDString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static void RDSwizzle(Class cls, SEL original, SEL replacement) {
    if (!cls) return;
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

static NSString *RDFormatBytes(unsigned long long bytes) {
    if (bytes >= 1024ULL * 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.2f GB", (double)bytes / (1024.0 * 1024.0 * 1024.0)];
    }
    if (bytes >= 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
    }
    if (bytes >= 1024ULL) {
        return [NSString stringWithFormat:@"%.0f KB", (double)bytes / 1024.0];
    }
    return [NSString stringWithFormat:@"%llu B", bytes];
}

static unsigned long long RDDirectorySize(NSString *path) {
    if (path.length == 0) return 0;
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
        return 0;
    }
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtPath:path];
    for (NSString *relative in enumerator) {
        NSString *full = [path stringByAppendingPathComponent:relative];
        NSDictionary *attributes = [manager attributesOfItemAtPath:full error:NULL];
        if ([[attributes fileType] isEqualToString:NSFileTypeRegular]) {
            total += [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
        }
    }
    return total;
}

static void RDShowAlert(NSString *title, NSString *message) {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:@"好"
                                          otherButtonTitles:nil];
    [alert show];
}

#pragma mark - Playback fix

@implementation RDPlayer (EnhancerPlayback)
- (void)rd_itemDidFinishPlaying:(NSNotification *)notification {
    AVPlayer *avPlayer = [self valueForKey:@"player"];
    AVPlayerItem *currentItem = avPlayer.currentItem;

    if (notification.object && currentItem && notification.object != currentItem) {
        return;
    }
    if (currentItem) {
        CMTime duration = currentItem.duration;
        CMTime current = avPlayer.currentTime;
        double durationSeconds = CMTimeGetSeconds(duration);
        double currentSeconds = CMTimeGetSeconds(current);
        if (CMTIME_IS_VALID(duration) && isfinite(durationSeconds) && durationSeconds > 1.0) {
            if (CMTIME_IS_VALID(current) && currentSeconds < durationSeconds - 1.5) {
                return;
            }
        }
    }
    [self rd_itemDidFinishPlaying:notification];
}
@end

#pragma mark - Favorites store

static NSString * const kRDFavoritesKey = @"RainyDayFavoritesV1";

@interface RDFavorites : NSObject
@property (nonatomic, strong) NSMutableArray *songs;
+ (instancetype)shared;
- (BOOL)containsSong:(RDSong *)song;
- (void)addSong:(RDSong *)song;
- (void)removeSong:(RDSong *)song;
- (void)toggleSong:(RDSong *)song;
- (NSArray *)albums;
- (NSString *)keyForSong:(RDSong *)song;
- (void)load;
- (void)save;
@end

@implementation RDFavorites

+ (instancetype)shared {
    static RDFavorites *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[RDFavorites alloc] init];
    });
    return store;
}

- (id)init {
    self = [super init];
    if (self) {
        self.songs = [NSMutableArray array];
        [self load];
    }
    return self;
}

- (NSString *)keyForSong:(RDSong *)song {
    NSString *sid = RDString(song.sid);
    if (sid.length) return sid;
    NSString *yid = RDString(song.yid);
    if (yid.length) return yid;
    return [NSString stringWithFormat:@"%@|%@", RDString(song.name), RDString(song.artist)];
}

- (void)load {
    NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:kRDFavoritesKey];
    for (NSDictionary *dictionary in raw) {
        RDSong *song = [RDSong songFromDictionary:dictionary];
        if (song) {
            [self.songs addObject:song];
        }
    }
}

- (void)save {
    NSMutableArray *raw = [NSMutableArray array];
    for (RDSong *song in self.songs) {
        NSDictionary *dictionary = [song dictionary];
        if (dictionary) {
            [raw addObject:dictionary];
        }
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:raw forKey:kRDFavoritesKey];
    [defaults synchronize];
}

- (BOOL)containsSong:(RDSong *)song {
    NSString *key = [self keyForSong:song];
    for (RDSong *candidate in self.songs) {
        if ([[self keyForSong:candidate] isEqualToString:key]) return YES;
    }
    return NO;
}

- (void)addSong:(RDSong *)song {
    if (!song || [self containsSong:song]) return;
    [self.songs addObject:song];
    [self save];
}

- (void)removeSong:(RDSong *)song {
    NSString *key = [self keyForSong:song];
    NSMutableArray *remove = [NSMutableArray array];
    for (RDSong *candidate in self.songs) {
        if ([[self keyForSong:candidate] isEqualToString:key]) {
            [remove addObject:candidate];
        }
    }
    for (RDSong *candidate in remove) {
        [self.songs removeObject:candidate];
    }
    [self save];
}

- (void)toggleSong:(RDSong *)song {
    if ([self containsSong:song]) {
        [self removeSong:song];
    } else {
        [self addSong:song];
    }
}

- (NSArray *)albums {
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (RDSong *song in self.songs) {
        NSString *album = RDString(song.album);
        if (album.length == 0) album = @"未知专辑";
        NSMutableArray *songs = [groups objectForKey:album];
        if (!songs) {
            songs = [NSMutableArray array];
            [groups setObject:songs forKey:album];
        }
        [songs addObject:song];
    }
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *album in [[groups allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                           album, @"name",
                           [groups objectForKey:album], @"songs", nil]];
    }
    return result;
}

@end

#pragma mark - Tools controller

@interface RDToolsViewController : UITableViewController
@end

@implementation RDToolsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"RainyDay 工具";
    self.tableView.backgroundColor = [UIColor colorWithRed:0.11 green:0.12 blue:0.14 alpha:1.0];
    self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                                             style:UIBarButtonItemStyleBordered
                                                                            target:self
                                                                            action:@selector(closeTapped:)];
}

- (void)closeTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"当前播放" : @"管理";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"RDToolCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.backgroundColor = [UIColor colorWithRed:0.16 green:0.17 blue:0.20 alpha:1.0];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
    }

    RDSong *song = [[RDPlayer shared] currentSong];
    RDFavorites *favorites = [RDFavorites shared];
    if (indexPath.section == 0 && indexPath.row == 0) {
        BOOL contains = song && [favorites containsSong:song];
        cell.textLabel.text = contains ? @"取消收藏当前歌曲" : @"收藏当前歌曲";
        cell.detailTextLabel.text = song ? RDString(song.name) : @"当前没有播放歌曲";
        cell.accessoryType = contains ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = @"收藏当前专辑";
        cell.detailTextLabel.text = song ? RDString(song.album) : @"当前没有播放歌曲";
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        cell.textLabel.text = @"我的收藏";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 首 · %lu 张专辑",
                                     (unsigned long)favorites.songs.count,
                                     (unsigned long)[favorites albums].count];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = @"缓存管理";
        cell.detailTextLabel.text = @"查看占用并清理";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 0) {
        [self toggleCurrentSong];
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        [self favoriteCurrentAlbum];
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        Class favoritesClass = NSClassFromString(@"RDFavoritesViewController");
        UIViewController *controller = [[favoritesClass alloc] initWithStyle:UITableViewStyleGrouped];
        [self.navigationController pushViewController:controller animated:YES];
    } else {
        Class cacheClass = NSClassFromString(@"RDCacheViewController");
        UIViewController *controller = [[cacheClass alloc] initWithStyle:UITableViewStyleGrouped];
        [self.navigationController pushViewController:controller animated:YES];
    }
}

- (void)toggleCurrentSong {
    RDSong *song = [[RDPlayer shared] currentSong];
    if (!song) {
        RDShowAlert(@"没有播放歌曲", @"先在 RainyDay 里播放一首歌。");
        return;
    }
    [[RDFavorites shared] toggleSong:song];
    [self.tableView reloadData];
}

- (void)favoriteCurrentAlbum {
    RDSong *song = [[RDPlayer shared] currentSong];
    if (!song) {
        RDShowAlert(@"没有播放歌曲", @"先在 RainyDay 里播放一首歌。");
        return;
    }
    NSString *album = RDString(song.album);
    if (album.length == 0) {
        RDShowAlert(@"没有专辑信息", @"这首歌没有专辑名，只能收藏单曲。");
        return;
    }
    NSArray *queue = [[RDPlayer shared] queue];
    NSMutableArray *albumSongs = [NSMutableArray array];
    for (RDSong *candidate in queue) {
        if ([RDString(candidate.album) isEqualToString:album]) {
            [albumSongs addObject:candidate];
        }
    }
    if (albumSongs.count == 0) {
        [albumSongs addObject:song];
    }
    for (RDSong *candidate in albumSongs) {
        [[RDFavorites shared] addSong:candidate];
    }
    [self.tableView reloadData];
    RDShowAlert(@"已收藏专辑", [NSString stringWithFormat:@"%@\n共 %lu 首", album, (unsigned long)albumSongs.count]);
}

@end

#pragma mark - Favorites controller

@interface RDFavoritesViewController : UITableViewController
@property (nonatomic, strong) NSArray *songs;
@property (nonatomic, strong) NSArray *albums;
@end

@implementation RDFavoritesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"我的收藏";
    self.tableView.backgroundColor = [UIColor colorWithRed:0.11 green:0.12 blue:0.14 alpha:1.0];
    self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}

- (void)reloadData {
    self.songs = [NSArray arrayWithArray:[RDFavorites shared].songs];
    self.albums = [[RDFavorites shared] albums];
    [self.tableView reloadData];
    if (self.songs.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:self.tableView.bounds];
        empty.backgroundColor = [UIColor clearColor];
        empty.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        empty.textAlignment = NSTextAlignmentCenter;
        empty.numberOfLines = 0;
        empty.text = @"还没有收藏\n在 RainyDay 工具里收藏当前歌曲或专辑";
        self.tableView.backgroundView = empty;
    } else {
        self.tableView.backgroundView = nil;
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)self.songs.count : (NSInteger)self.albums.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return [NSString stringWithFormat:@"单曲（%lu）", (unsigned long)self.songs.count];
    }
    return [NSString stringWithFormat:@"专辑（%lu）", (unsigned long)self.albums.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        static NSString *identifier = @"RDFavSongCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
            cell.backgroundColor = [UIColor colorWithRed:0.16 green:0.17 blue:0.20 alpha:1.0];
            cell.textLabel.textColor = [UIColor whiteColor];
            cell.detailTextLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        }
        RDSong *song = [self.songs objectAtIndex:indexPath.row];
        cell.textLabel.text = RDString(song.name);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", RDString(song.artist), RDString(song.album)];
        return cell;
    }

    static NSString *identifier = @"RDFavAlbumCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];
        cell.backgroundColor = [UIColor colorWithRed:0.16 green:0.17 blue:0.20 alpha:1.0];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    }
    NSDictionary *album = [self.albums objectAtIndex:indexPath.row];
    cell.textLabel.text = [album objectForKey:@"name"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 首", (unsigned long)[[album objectForKey:@"songs"] count]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        NSArray *queue = self.songs;
        RDSong *song = [queue objectAtIndex:indexPath.row];
        [[RDPlayer shared] playSong:song inQueue:queue];
    } else {
        NSArray *queue = [[self.albums objectAtIndex:indexPath.row] objectForKey:@"songs"];
        if (queue.count) {
            [[RDPlayer shared] playSong:[queue objectAtIndex:0] inQueue:queue];
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    RDSong *song = [self.songs objectAtIndex:indexPath.row];
    [[RDFavorites shared] removeSong:song];
    [self reloadData];
}

@end

#pragma mark - Cache controller

@interface RDCacheViewController : UITableViewController <UIAlertViewDelegate>
@property (nonatomic, strong) RDCache *cache;
@property (nonatomic, assign) unsigned long long coverSize;
@property (nonatomic, assign) unsigned long long songSize;
@property (nonatomic, assign) unsigned long long lyricSize;
@property (nonatomic, assign) unsigned long long offlineSize;
@property (nonatomic, assign) NSUInteger offlineCount;
@end

@implementation RDCacheViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"缓存管理";
    self.tableView.backgroundColor = [UIColor colorWithRed:0.11 green:0.12 blue:0.14 alpha:1.0];
    self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.cache = [RDCache shared];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)refresh {
    self.coverSize = RDDirectorySize(self.cache.coverDir);
    self.songSize = RDDirectorySize(self.cache.songDir);
    self.lyricSize = RDDirectorySize(self.cache.lyricDir);
    self.offlineSize = RDDirectorySize(self.cache.offlineDir);
    self.offlineCount = [self.cache offlineSongs].count;
    [self.tableView reloadData];
}

- (unsigned long long)totalSize {
    return self.coverSize + self.songSize + self.lyricSize + self.offlineSize;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 5 : 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"当前占用" : @"清理";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"清理前会先弹窗确认。离线歌曲删除后需要重新下载。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"RDCacheCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];
        cell.backgroundColor = [UIColor colorWithRed:0.16 green:0.17 blue:0.20 alpha:1.0];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"总占用";
            cell.detailTextLabel.text = RDFormatBytes([self totalSize]);
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"封面缓存";
            cell.detailTextLabel.text = RDFormatBytes(self.coverSize);
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"歌曲缓存";
            cell.detailTextLabel.text = RDFormatBytes(self.songSize);
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"歌词缓存";
            cell.detailTextLabel.text = RDFormatBytes(self.lyricSize);
        } else {
            cell.textLabel.text = @"离线歌曲";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 首 · %@", (unsigned long)self.offlineCount, RDFormatBytes(self.offlineSize)];
        }
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"清空封面缓存";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"清空歌曲/歌词缓存";
        } else {
            cell.textLabel.text = @"清空全部缓存";
            cell.textLabel.textColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.38 alpha:1.0];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    NSInteger tag = indexPath.row + 1;
    NSString *title = nil;
    if (tag == 1) title = @"清空封面缓存";
    else if (tag == 2) title = @"清空歌曲/歌词缓存";
    else title = @"清空全部缓存";
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:[NSString stringWithFormat:@"当前总占用 %@，确定清理？", RDFormatBytes([self totalSize])]
                                                   delegate:self
                                          cancelButtonTitle:@"取消"
                                          otherButtonTitles:@"清理", nil];
    alert.tag = tag;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex != 1) return;
    if (alertView.tag == 1) {
        [self clearDirectory:self.cache.coverDir];
    } else if (alertView.tag == 2) {
        [self clearDirectory:self.cache.songDir];
        [self clearDirectory:self.cache.lyricDir];
    } else {
        [self clearDirectory:self.cache.coverDir];
        [self clearDirectory:self.cache.songDir];
        [self clearDirectory:self.cache.lyricDir];
        [self clearOfflineSongs];
    }
    [self refresh];
    RDShowAlert(@"已清理", [NSString stringWithFormat:@"当前占用 %@", RDFormatBytes([self totalSize])]);
}

- (void)clearDirectory:(NSString *)path {
    if (path.length == 0) return;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *items = [manager contentsOfDirectoryAtPath:path error:NULL];
    for (NSString *item in items) {
        [manager removeItemAtPath:[path stringByAppendingPathComponent:item] error:NULL];
    }
}

- (void)clearOfflineSongs {
    NSArray *songs = [NSArray arrayWithArray:[self.cache offlineSongs]];
    for (id song in songs) {
        [self.cache removeOfflineSong:song];
    }
}

@end

#pragma mark - Main controller hook

@implementation RDMainViewController (EnhancerUI)
- (void)rd_viewDidAppear:(BOOL)animated {
    [self rd_viewDidAppear:animated];
    [self rd_installToolsButton];
}

- (void)rd_installToolsButton {
    if (!self.view) return;
    if ([self.view viewWithTag:0x524454]) return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    button.frame = CGRectMake(width - 58.0, height - 150.0, 46.0, 46.0);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    button.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:0.92];
    button.layer.cornerRadius = 23.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.22] CGColor];
    button.layer.shadowColor = [[UIColor blackColor] CGColor];
    button.layer.shadowOpacity = 0.5;
    button.layer.shadowRadius = 4.0;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.titleLabel.font = [UIFont boldSystemFontOfSize:22.0];
    [button setTitle:@"♥" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithRed:1.0 green:0.45 blue:0.55 alpha:1.0] forState:UIControlStateNormal];
    button.tag = 0x524454;
    [button addTarget:self action:@selector(rd_openTools:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
}

- (void)rd_openTools:(id)sender {
    RDToolsViewController *tools = [[RDToolsViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:tools];
    navigation.navigationBar.barStyle = UIBarStyleBlack;
    [self presentViewController:navigation animated:YES completion:nil];
}
@end

#pragma mark - Constructor

__attribute__((constructor))
static void RainyDayEnhancerInit(void) {
    Class playerClass = objc_getClass("RDPlayer");
    if (playerClass) {
        RDSwizzle(playerClass, @selector(itemDidFinishPlaying:), @selector(rd_itemDidFinishPlaying:));
    }
    Class mainClass = objc_getClass("RDMainViewController");
    if (mainClass) {
        RDSwizzle(mainClass, @selector(viewDidAppear:), @selector(rd_viewDidAppear:));
    }
}
