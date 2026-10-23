Pod::Spec.new do |s|
  s.name = 'IJKMediaFramework'
  s.version = '0.1.5'
  s.summary = 'ijkplayer 预编译 IJKMediaFramework（本地归档）'
  s.description = '本地归档的 IJKMediaFramework.framework，避免从 Gitee 拉取 git 仓库导致传输中断。'
  s.homepage = 'https://github.com/fadeds/addons-lite'
  s.license = { :type => 'LGPL', :text => 'IJKPlayer 为 LGPL 许可。' }
  s.author = 'bilibili'
  s.platform = :ios, '16.0'

  s.static_framework = true
  s.source = { :git => 'https://github.com/fadeds/addons-lite.git', :tag => 'local' }
  s.prepare_command = "rm -rf vendor/IJKMediaFramework.framework && unzip -q vendor/IJKMediaFramework.zip"
  s.vendored_frameworks = 'vendor/IJKMediaFramework.framework'
  s.preserve_paths = 'vendor/IJKMediaFramework.zip'

  s.frameworks = 'AVFoundation', 'AudioToolbox', 'CoreGraphics', 'CoreMedia', 'CoreText', 'GLKit', 'MediaPlayer', 'OpenGLES', 'QuartzCore', 'Security', 'UIKit', 'AssetsLibrary', 'Foundation', 'MobileCoreServices', 'SystemConfiguration', 'CoreTelephony', 'CFNetwork', 'WebKit'
  s.libraries = 'bz2', 'z', 'c++'
end
