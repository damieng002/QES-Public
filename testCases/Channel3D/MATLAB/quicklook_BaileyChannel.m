mainpath='../QES-data';

testcases = {'BaileyChannel_1o83_18o3', 'BaileyChannel_0o183_18o3', 'BaileyChannel_0o00183_18o3'};

for k=1:numel(testcases)
    f=testcases{k};
    filename=sprintf('%s/%s_%s.nc',mainpath,f,'particleInfo');
    [particleInfo.(f).data,particleInfo.(f).varname] = readNetCDF(filename);
end

for k=1:numel(testcases)
    f=testcases{k};
    filename=sprintf('%s/%s_%s.nc',mainpath,f,'conc');
    [Concentration.(f).data,Concentration.(f).varname] = readNetCDF(filename);
end

figure()
for k=1:numel(testcases)
    f=testcases{k};
    subplot(1,3,k)
    histogram(particleInfo.(f).data.zPos(:,end),25,'Normalization','pdf','Orientation','horizontal')
    hold all
    plot([1 1],[0 1],'k--')
    ylabel('$z/\delta$')
    xlabel('p.d.f.')
    xlim([0 1.5])
    ylim([0 1])
    
    [ppBin,edgesBin]=histcounts(particleInfo.(f).data.zPos(:,end),25,'Normalization','pdf');
    S=-sum(ppBin.*log(ppBin))
end

figure()
for k=1:numel(testcases)
    f=testcases{k};
    subplot(1,3,k)
    plot(squeeze(mean(mean(Concentration.(f).data.conc(:,:,:,end),1),2)),Concentration.(f).data.z)
    ylabel('$z/\delta$')
    xlabel('\#part/vol')
end