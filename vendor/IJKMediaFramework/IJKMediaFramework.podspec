Pod::Spec.new do |s|
  s.name = 'IJKMediaFramework'
  s.version = '0.1.5'
  s.summary = 'ijkplayer 预编译 IJKMediaFramework（本仓本地归档）'
  s.description = '本地归档的 IJKMediaFramework.framework，避免 CI 从 Gitee 拉取 git 仓库导致传输中断。'
  s.homepage = 'https://github.com/fadeds/addons-lite'
  s.license = { :type => 'LGPL', :text => 'IJKPlayer 为 LGPL 许可。' }
  s.author = 'bilibili'
  s.platform = :ios, '16.0'
  s.source = { :http => 'https://github.com/fadeds/addons-lite/archive/refs/heads/master.zip' }

  s.static_framework = true
  s.vendored_frameworks = 'IJKMediaFramework.framework'

  s.frameworks = 'AVFoundation', 'AVFAudio', 'AVKit', 'AudioToolbox', 'AssetsLibrary', 'CFNetwork', 'CoreAudio', 'CoreGraphics', 'CoreMedia', 'CoreMotion', 'CoreTelephony', 'CoreText', 'CoreVideo', 'Foundation', 'GLKit', 'ImageIO', 'MediaPlayer', 'MobileCoreServices', 'NetworkExtension', 'OpenGLES', 'QuartzCore', 'Security', 'SystemConfiguration', 'UIKit', 'VideoToolbox', 'WebKit'
  s.libraries = 'bz2', 'z', 'c++'
end
