classdef SplitFieldCentering < edu.washington.rieke.protocols.RiekeStageProtocol
    
    properties
        preTime = 250 % ms
        stimTime = 2000 % ms
        tailTime = 250 % ms
        contrast = 0.9 % relative to mean (0-1)
        cycleFrequency = 4; % Hz
        spotDiameter = 300; % um
        splitField = false; 
        rotation = 0;  deg
        backgroundIntensity = 0.5 % (0-1)
        centerOffset = [0, 0] % [x,y] (um)
        onlineAnalysis = 'none'
        numberOfAverages = uint16(1) % number of epochs to queue
        amp % Output amplifier
    end
    
    properties (Hidden)
        ampType
        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'exc', 'inh'})
        analysisFigure
    end

    methods
        
        function didSetRig(obj)
            didSetRig@edu.washington.rieke.protocols.RiekeStageProtocol(obj);
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end
        
        function p = getPreview(obj, panel)
            if isempty(obj.rig.getDevices('Stage'))
                p = [];
                return;
            end
            p = io.github.stage_vss.previews.StagePreview(panel, @()obj.createPresentation(), ...
                'windowSize', obj.rig.getDevice('Stage').getCanvasSize());
        end

        function prepareRun(obj)
            prepareRun@edu.washington.rieke.protocols.RiekeStageProtocol(obj);
            
            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
            obj.showFigure('symphonyui.builtin.figures.MeanResponseFigure', obj.rig.getDevice(obj.amp));
            obj.showFigure('io.github.stage_vss.figures.FrameTimingFigure', obj.rig.getDevice('Stage'));
            if ~strcmp(obj.onlineAnalysis,'none')
                % custom figure handler
                if isempty(obj.analysisFigure) || ~isvalid(obj.analysisFigure)
                    obj.analysisFigure = obj.showFigure('symphonyui.builtin.figures.CustomFigure', @obj.F1F2_PSTH);
                    f = obj.analysisFigure.getFigureHandle();
                    set(f, 'Name', 'Cycle avg PSTH');
                    obj.analysisFigure.userData.runningTrace = 0;
                    obj.analysisFigure.userData.axesHandle = axes('Parent', f);
                end
            end
        end
        
        function F1F2_PSTH(obj, ~, epoch) %online analysis function
            response = epoch.getResponse(obj.rig.getDevice(obj.amp));
            quantities = response.getData();
            sampleRate = response.sampleRate.quantityInBaseUnits;
            
            axesHandle = obj.analysisFigure.userData.axesHandle;
            runningTrace = obj.analysisFigure.userData.runningTrace;
            
            if strcmp(obj.onlineAnalysis,'extracellular') %spike recording
                filterSigma = (5/1000)*sampleRate; %msec -> dataPts
                newFilt = normpdf(1:10*filterSigma,10*filterSigma/2,filterSigma);
                res = spikeDetectorOnline(quantities,[],sampleRate);
                epochResponseTrace = zeros(size(quantities));
                epochResponseTrace(res.sp) = 1; %spike binary
                epochResponseTrace = sampleRate*conv(epochResponseTrace,newFilt,'same'); %inst firing rate
            else %intracellular - Vclamp
                epochResponseTrace = quantities-mean(quantities(1:sampleRate*obj.preTime/1000)); %baseline
                if strcmp(obj.onlineAnalysis,'exc') %measuring exc
                    epochResponseTrace = epochResponseTrace./(-60-0); %conductance (nS), ballpark
                elseif strcmp(obj.onlineAnalysis,'inh') %measuring inh
                    epochResponseTrace = epochResponseTrace./(0-(-60)); %conductance (nS), ballpark
                end
            end
            
            noCycles = floor(obj.cycleFrequency*obj.stimTime/1000);
            period = (1/obj.cycleFrequency)*sampleRate; %data points
            epochResponseTrace(1:(sampleRate*obj.preTime/1000)) = []; %cut out prePts
            cycleAvgResp = 0;
            for c = 1:noCycles
                cycleAvgResp = cycleAvgResp + epochResponseTrace((c-1)*period+1:c*period);
            end
            cycleAvgResp = cycleAvgResp./noCycles;
            timeVector = (1:length(cycleAvgResp))./sampleRate; %sec
            runningTrace = runningTrace + cycleAvgResp;
            cla(axesHandle);
            h = line(timeVector, runningTrace./obj.numEpochsCompleted, 'Parent', axesHandle);
            set(h,'Color',[0 0 0],'LineWidth',2);
            xlabel(axesHandle,'Time (s)')
            title(axesHandle,'Running cycle average...')
            if strcmp(obj.onlineAnalysis,'extracellular')
                ylabel(axesHandle,'Spike rate (Hz)')
            else
                ylabel(axesHandle,'Resp (nS)')
            end
            obj.analysisFigure.userData.runningTrace = runningTrace;
        end
        
        function p = createPresentation(obj)
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            
            %convert from microns to pixels...
            spotDiameterPix = obj.um2pix(obj.spotDiameter);
            centerOffsetPix = obj.um2pix(obj.centerOffset);
            
            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3); %create presentation of specified duration
            p.setBackgroundColor(obj.backgroundIntensity); % Set background intensity
            
            % Create grating stimulus.            
            grate = stage.builtin.stimuli.Grating('square'); %square wave grating
            grate.orientation = obj.rotation;
            grate.size = [spotDiameterPix, spotDiameterPix];
            grate.position = canvasSize/2 + centerOffsetPix;
            grate.spatialFreq = 1/(2*spotDiameterPix);
            grate.color = 2*obj.backgroundIntensity; %amplitude of square wave
            grate.contrast = obj.contrast; %multiplier on square wave
            if (obj.splitField)
                grate.phase = 90;
            else %full-field
                grate.phase = 0;
            end
            p.addStimulus(grate); %add grating to the presentation
            
            %make it contrast-reversing
            if (obj.cycleFrequency>0) 
                grateContrast = stage.builtin.controllers.PropertyController(grate, 'contrast',...
                    @(state)getGrateContrast(obj, state.time - obj.preTime/1e3));
                p.addController(grateContrast); %add the controller
            end
            function c = getGrateContrast(obj, time)
                c = obj.contrast.*sin(2 * pi * obj.cycleFrequency * time);
            end
            
            % Create aperture
            aperture = stage.builtin.stimuli.Rectangle();
            aperture.position = canvasSize/2 + centerOffsetPix;
            aperture.color = obj.backgroundIntensity;
            aperture.size = [2*max(canvasSize), 2*max(canvasSize)];
            mask = stage.core.Mask.createCircularAperture(spotDiameterPix/(2*max(canvasSize)), 1024); %circular aperture
            aperture.setMask(mask);
            p.addStimulus(aperture); %add aperture
            
            %hide during pre & post
            grateVisible = stage.builtin.controllers.PropertyController(grate, 'visible', ...
                @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
            p.addController(grateVisible);

        end
        
        function prepareEpoch(obj, epoch)
            prepareEpoch@edu.washington.rieke.protocols.RiekeStageProtocol(obj, epoch);
            
            device = obj.rig.getDevice(obj.amp);
            duration = (obj.preTime + obj.stimTime + obj.tailTime) / 1e3;
            epoch.addDirectCurrentStimulus(device, device.background, duration, obj.sampleRate);
            epoch.addResponse(device);
        end
        
        
        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages;
        end
        
        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages;
        end
        
    end
    
end