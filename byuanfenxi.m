clc;
clear;
close all;

%% ===================== 参数设置 =====================

% 图片所在文件夹
imgDir = '截图结果';

% 图片格式：分析文件夹中全部 BMP 图片
imgExt = '*.bmp';

% 每张图片之间的时间间隔，单位：min
timeInterval_min = 1;

% 是否手动选择ROI
useManualROI = true;

% 如果 useManualROI = false，就使用下面固定的圆形ROI
% 圆心坐标 [x y]，半径单位为像素
roiCenter = [300 300];
roiRadius = 50;

% 背景区域：[x y width height]
bgRect = [20 20 120 80];

%% ===================== 读取图片列表 =====================

% 读取文件夹内所有 BMP 图片
files = dir(fullfile(imgDir, imgExt));

% 排除文件夹
files = files(~[files.isdir]);

% 如果没有图片，直接报错
if isempty(files)
    error('没有找到 BMP 图片，请检查 imgDir 和 imgExt 设置。');
end

% ================= 按文件名中的数字排序 =================
% 例如：1.bmp, 2.bmp, 3.bmp, ..., 10.bmp
fileNums = nan(length(files), 1);

for i = 1:length(files)
    [~, nameOnly, ~] = fileparts(files(i).name);
    fileNums(i) = str2double(nameOnly);
end

% 检查是否都是纯数字文件名
if any(isnan(fileNums))
    error(['检测到非纯数字命名的 BMP 文件。' newline ...
           '请保证文件名类似 1.bmp, 2.bmp, 3.bmp ...']);
end

% 按数字升序排序
[~, sortIdx] = sort(fileNums);
files = files(sortIdx);

numImgs = length(files);

fprintf('共找到 %d 张 BMP 图片。\n', numImgs);

% 显示实际分析顺序
fprintf('\n实际分析顺序：\n');
for i = 1:numImgs
    fprintf('%d. %s\n', i, files(i).name);
end

%% ===================== 第一张图：选择圆形ROI =====================

firstImg = imread(fullfile(imgDir, files(1).name));

figure;
imshow(firstImg);
title(['第一张图：', files(1).name]);

if useManualROI

    % 选择样本圆形ROI
    figure;
    imshow(firstImg);
    title('画红色圆圈：样本荧光分析区域，双击圆圈确认');

    h1 = drawcircle('Color', 'r', 'LineWidth', 1.5);
    wait(h1);

    roiCenter = round(h1.Center);
    roiRadius = round(h1.Radius);
    close;

    % 选择背景矩形ROI
    figure;
    imshow(firstImg);
    title('框选蓝色矩形：背景区域，双击矩形确认');

    h2 = drawrectangle('Color', 'b', 'LineWidth', 1.5);
    wait(h2);

    bgRect = round(h2.Position);
    close;
end

fprintf('\n样本圆形ROI：圆心 = [%d, %d]，半径 = %d 像素\n', ...
    roiCenter(1), roiCenter(2), roiRadius);

fprintf('背景矩形ROI = [%d %d %d %d]\n', bgRect);

%% ===================== 初始化结果 =====================

time_min = (0:numImgs-1)' * timeInterval_min;

fileName = strings(numImgs, 1);

roiMean = zeros(numImgs, 1);
roiMedian = zeros(numImgs, 1);
roiMax = zeros(numImgs, 1);
roiMin = zeros(numImgs, 1);
roiSum = zeros(numImgs, 1);

bgMean = zeros(numImgs, 1);
bgMedian = zeros(numImgs, 1);

netMean = zeros(numImgs, 1);
netMedian = zeros(numImgs, 1);
netIntegrated = zeros(numImgs, 1);

satPercent = zeros(numImgs, 1);

%% ===================== 批量分析图片 =====================

for k = 1:numImgs

    imgPath = fullfile(imgDir, files(k).name);
    img = imread(imgPath);

    fileName(k) = string(files(k).name);

    % 提取绿色通道；灰度图则直接使用灰度值
    if ndims(img) >= 3 && size(img, 3) >= 3
        G = double(img(:, :, 2));
    else
        G = double(img);
    end

    % 提取圆形样本ROI内像素
    roi = getCirclePixels(G, roiCenter, roiRadius);

    % 提取背景矩形ROI
    bg = getRectImage(G, bgRect);

    % ROI基础统计
    roiMean(k) = mean(roi);
    roiMedian(k) = median(roi);
    roiMax(k) = max(roi);
    roiMin(k) = min(roi);
    roiSum(k) = sum(roi);

    % 背景统计
    bgMean(k) = mean(bg(:));
    bgMedian(k) = median(bg(:));

    % 背景扣除后的平均荧光
    netMean(k) = roiMean(k) - bgMean(k);
    netMedian(k) = roiMedian(k) - bgMedian(k);

    % 背景扣除后的积分荧光
    netIntegrated(k) = roiSum(k) - bgMean(k) * numel(roi);

    % 8-bit图片中接近过曝的像素比例
    satPercent(k) = sum(roi >= 250) / numel(roi) * 100;

    fprintf('第 %02d 张：%s | Mean-bg = %.2f | Integrated = %.2f | Saturation = %.2f%%\n', ...
        k, files(k).name, netMean(k), netIntegrated(k), satPercent(k));
end

%% ===================== 归一化 =====================

if max(netMean) ~= min(netMean)
    normMean = (netMean - min(netMean)) ./ (max(netMean) - min(netMean));
else
    normMean = zeros(numImgs, 1);
end

if max(netIntegrated) ~= min(netIntegrated)
    normIntegrated = (netIntegrated - min(netIntegrated)) ./ ...
        (max(netIntegrated) - min(netIntegrated));
else
    normIntegrated = zeros(numImgs, 1);
end

%% ===================== 起扩时间 Tt 粗略判断 =====================

baselineN = min(6, numImgs);

baseMean = mean(netMean(1:baselineN));
baseStd = std(netMean(1:baselineN));

threshold = baseMean + 3 * baseStd;

idxTt = find(netMean > threshold, 1, 'first');

if ~isempty(idxTt)
    Tt_min = time_min(idxTt);
    fprintf('\n起扩时间 Tt ≈ %.2f min\n', Tt_min);
else
    Tt_min = NaN;
    fprintf('\n未检测到明显起扩点。\n');
end

%% ===================== 平均荧光曲线 =====================

figure;
plot(time_min, netMean, '-o', 'LineWidth', 2);
hold on;

yline(threshold, '--', 'Threshold', 'LineWidth', 1.5);

if ~isnan(Tt_min)
    plot(Tt_min, netMean(idxTt), 'ro', 'MarkerSize', 10, 'LineWidth', 2);
    text(Tt_min, netMean(idxTt), sprintf('  Tt = %.2f min', Tt_min), ...
        'FontSize', 12);
end

xlabel('Time (min)');
ylabel('Net mean green fluorescence');
title('LAMP fluorescence curve');
grid on;

saveas(gcf, fullfile(imgDir, 'LAMP_curve_mean.png'));

%% ===================== 归一化曲线 =====================

figure;
plot(time_min, normMean, '-o', 'LineWidth', 2);

xlabel('Time (min)');
ylabel('Normalized fluorescence');
title('Normalized LAMP fluorescence curve');
grid on;

saveas(gcf, fullfile(imgDir, 'LAMP_curve_normalized.png'));

%% ===================== 积分荧光曲线 =====================

figure;
plot(time_min, netIntegrated, '-o', 'LineWidth', 2);

xlabel('Time (min)');
ylabel('Net integrated green fluorescence');
title('Integrated LAMP fluorescence curve');
grid on;

saveas(gcf, fullfile(imgDir, 'LAMP_curve_integrated.png'));

%% ===================== 导出Excel =====================

Result = table( ...
    (1:numImgs)', ...
    fileName, ...
    time_min, ...
    roiMean, ...
    roiMedian, ...
    roiMax, ...
    roiMin, ...
    bgMean, ...
    bgMedian, ...
    netMean, ...
    netMedian, ...
    netIntegrated, ...
    normMean, ...
    normIntegrated, ...
    satPercent, ...
    'VariableNames', { ...
    'Image_Index', ...
    'File_Name', ...
    'Time_min', ...
    'ROI_Mean_Green', ...
    'ROI_Median_Green', ...
    'ROI_Max_Green', ...
    'ROI_Min_Green', ...
    'Background_Mean_Green', ...
    'Background_Median_Green', ...
    'Net_Mean_Green', ...
    'Net_Median_Green', ...
    'Net_Integrated_Green', ...
    'Normalized_Mean', ...
    'Normalized_Integrated', ...
    'Saturated_Pixel_Percent'});

outExcel = fullfile(imgDir, 'LAMP_image_fluorescence_result.xlsx');

writetable(Result, outExcel);

ROI_Info = table( ...
    roiCenter(1), roiCenter(2), roiRadius, ...
    bgRect(1), bgRect(2), bgRect(3), bgRect(4), ...
    'VariableNames', { ...
    'ROI_Center_X', 'ROI_Center_Y', 'ROI_Radius', ...
    'BG_X', 'BG_Y', 'BG_Width', 'BG_Height'});

writetable(ROI_Info, outExcel, 'Sheet', 'ROI_information');

fprintf('\n分析完成。\n');
fprintf('Excel文件：%s\n', outExcel);

%% ===================== 小函数 =====================

function pixels = getCirclePixels(img, center, radius)

    [X, Y] = meshgrid(1:size(img, 2), 1:size(img, 1));

    mask = (X - center(1)).^2 + (Y - center(2)).^2 <= radius^2;

    pixels = img(mask);

    if isempty(pixels)
        error('圆形ROI超出图像范围，请重新画圆。');
    end
end

function subImg = getRectImage(img, rect)

    x = round(rect(1));
    y = round(rect(2));
    w = round(rect(3));
    h = round(rect(4));

    x1 = max(1, x);
    y1 = max(1, y);
    x2 = min(size(img, 2), x + w - 1);
    y2 = min(size(img, 1), y + h - 1);

    subImg = img(y1:y2, x1:x2);

    if isempty(subImg)
        error('背景ROI超出图像范围，请重新框选。');
    end
end