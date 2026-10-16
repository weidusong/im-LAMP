clc;
clear;
close all;

%% ===================== 参数设置 =====================

% 视频文件名
videoFile = 'Record_31.mp4';

% 截图输出文件夹
outDir = '截图结果';

% 图片格式
imgFormat = 'bmp';

% 每秒分析多少帧
% 5表示每秒检测5次，通常足够
detectFPS = 5;

% 自动识别阈值比例
% 误判亮灯时调大，例如0.45
% 漏掉较暗的亮灯时调小，例如0.25
thresholdRatio = 0.1;

% 最短亮灯时间，单位：秒
% 小于这个时间的瞬间闪光会被忽略
minLightTime = 1.0;

% 允许亮灯过程中短暂变暗的时间，单位：秒
maxDarkGapTime = 1.0;

%% ===================== 创建并清空输出文件夹 =====================

if ~exist(outDir, 'dir')
    mkdir(outDir);
else
    oldFiles = dir(fullfile(outDir, ['*.' imgFormat]));

    for i = 1:length(oldFiles)
        delete(fullfile(outDir, oldFiles(i).name));
    end
end

%% ===================== 打开视频 =====================

v = VideoReader(videoFile);

fps = v.FrameRate;
duration = v.Duration;

% 每隔多少帧进行一次亮度分析
sampleStep = max(1, round(fps / detectFPS));

% 实际分析频率
actualDetectFPS = fps / sampleStep;

fprintf('视频总时长：%.2f s = %.2f min\n', ...
    duration, duration/60);

fprintf('视频帧率：%.2f fps\n', fps);
fprintf('亮灯检测频率：%.2f 次/s\n', actualDetectFPS);
fprintf('\n正在逐帧检测亮灯，请稍候……\n');

%% ===================== 第一次读取：分析亮度 =====================

frameNumber = 0;
sampleNumber = 0;

sampleFrames = [];
brightnessScore = [];

while hasFrame(v)

    frame = readFrame(v);
    frameNumber = frameNumber + 1;

    % 不需要每一帧都计算亮度
    if mod(frameNumber - 1, sampleStep) ~= 0
        continue;
    end

    sampleNumber = sampleNumber + 1;

    [height, width, ~] = size(frame);

    % 自动使用画面中央区域
    % 避开四周以及右上角的视频时间文字
    x1 = round(width  * 0.10);
    x2 = round(width  * 0.90);
    y1 = round(height * 0.15);
    y2 = round(height * 0.90);

    roi = frame(y1:y2, x1:x2, :);

    % 缩小计算量
    roi = roi(1:3:end, 1:3:end, :);

    % 计算每个像素RGB中的最大亮度
    pixelBrightness = max(double(roi), [], 3);

    % 从大到小排列
    sortedBrightness = sort(pixelBrightness(:), 'descend');

    % 使用最亮的前2%像素计算亮灯强度
    topNumber = max(1, round(numel(sortedBrightness) * 0.02));

    score = mean(sortedBrightness(1:topNumber));

    sampleFrames(sampleNumber, 1) = frameNumber;
    brightnessScore(sampleNumber, 1) = score;
end

if length(brightnessScore) < 10
    error('视频过短，无法完成亮灯检测。');
end

%% ===================== 平滑亮度曲线 =====================

smoothNumber = max(1, round(actualDetectFPS * 0.4));

smoothKernel = ones(smoothNumber, 1) / smoothNumber;

smoothScore = conv(brightnessScore, smoothKernel, 'same');

%% ===================== 自动计算亮灯阈值 =====================

% 对亮度数据进行一维双聚类
sortedScore = sort(smoothScore);

n = length(sortedScore);

lowCenter = sortedScore(max(1, round(n * 0.20)));
highCenter = sortedScore(max(1, round(n * 0.90)));

for iteration = 1:50

    lowGroup = abs(smoothScore - lowCenter) <= ...
               abs(smoothScore - highCenter);

    highGroup = ~lowGroup;

    if ~any(lowGroup) || ~any(highGroup)
        break;
    end

    newLowCenter = mean(smoothScore(lowGroup));
    newHighCenter = mean(smoothScore(highGroup));

    if abs(newLowCenter - lowCenter) < 0.001 && ...
       abs(newHighCenter - highCenter) < 0.001
        break;
    end

    lowCenter = newLowCenter;
    highCenter = newHighCenter;
end

% 保证lowCenter代表熄灯，highCenter代表亮灯
if lowCenter > highCenter
    temporaryValue = lowCenter;
    lowCenter = highCenter;
    highCenter = temporaryValue;
end

if abs(highCenter - lowCenter) < 1
    error('没有检测到明显的亮灯和熄灯变化。');
end

% 自动亮灯阈值
lightThreshold = lowCenter + ...
    thresholdRatio * (highCenter - lowCenter);

% 判断每个采样点是否亮灯
isLightOn = smoothScore > lightThreshold;

fprintf('熄灯平均亮度：%.2f\n', lowCenter);
fprintf('亮灯平均亮度：%.2f\n', highCenter);
fprintf('自动判断阈值：%.2f\n', lightThreshold);

%% ===================== 找出所有亮灯区间 =====================

stateChange = diff([false; isLightOn(:); false]);

lightStart = find(stateChange == 1);
lightEnd = find(stateChange == -1) - 1;

% 允许亮灯过程中存在短暂变暗
maxDarkGapSamples = round(maxDarkGapTime * actualDetectFPS);

% 最短有效亮灯长度
minLightSamples = max(1, ...
    round(minLightTime * actualDetectFPS));

mergedStart = [];
mergedEnd = [];

if ~isempty(lightStart)

    currentStart = lightStart(1);
    currentEnd = lightEnd(1);

    for i = 2:length(lightStart)

        darkGap = lightStart(i) - currentEnd - 1;

        if darkGap <= maxDarkGapSamples
            % 两段亮灯合并
            currentEnd = lightEnd(i);
        else
            % 保存上一段有效亮灯
            if currentEnd - currentStart + 1 >= minLightSamples
                mergedStart(end+1, 1) = currentStart;
                mergedEnd(end+1, 1) = currentEnd;
            end

            currentStart = lightStart(i);
            currentEnd = lightEnd(i);
        end
    end

    % 保存最后一段
    if currentEnd - currentStart + 1 >= minLightSamples
        mergedStart(end+1, 1) = currentStart;
        mergedEnd(end+1, 1) = currentEnd;
    end
end

numberOfEvents = length(mergedStart);

if numberOfEvents == 0
    error(['没有找到有效亮灯区间。可以把thresholdRatio从0.35' ...
           '改为0.25后再次运行。']);
end

fprintf('\n共检测到 %d 次亮灯。\n\n', numberOfEvents);

%% ===================== 计算每次亮灯的中间帧 =====================

middleFrames = zeros(numberOfEvents, 1);

for i = 1:numberOfEvents

    % 亮灯区间的中间位置
    middleSample = round( ...
        (mergedStart(i) + mergedEnd(i)) / 2);

    middleFrames(i) = sampleFrames(middleSample);

    startTime = (sampleFrames(mergedStart(i)) - 1) / fps;
    endTime = (sampleFrames(mergedEnd(i)) - 1) / fps;
    middleTime = (middleFrames(i) - 1) / fps;

    fprintf(['第 %d 次亮灯：开始 %.2f s，结束 %.2f s，' ...
             '中间 %.2f s\n'], ...
             i, startTime, endTime, middleTime);
end

%% ===================== 第二次读取：保存中间帧 =====================

fprintf('\n正在保存每次亮灯的中间截图……\n');

v2 = VideoReader(videoFile);

frameNumber = 0;
eventNumber = 1;

while hasFrame(v2) && eventNumber <= numberOfEvents

    frame = readFrame(v2);
    frameNumber = frameNumber + 1;

    if frameNumber >= middleFrames(eventNumber)

        fileName = sprintf('%d.%s', ...
            eventNumber, imgFormat);

        savePath = fullfile(outDir, fileName);

        imwrite(frame, savePath);

        fprintf('已保存第 %d 次亮灯的中间截图：%s\n', ...
            eventNumber, fileName);

        eventNumber = eventNumber + 1;
    end
end

%% ===================== 完成 =====================

fprintf('\n全部完成！\n');
fprintf('共保存 %d 张截图。\n', eventNumber - 1);
fprintf('截图保存在文件夹：%s\n', outDir);