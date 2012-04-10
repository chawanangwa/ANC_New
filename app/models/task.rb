class Task < ActiveRecord::Base
  set_table_name :anc_tasks
  set_primary_key :task_id
  include Openmrs

  # Try to find the next task for the patient at the given location
  def self.next_task(location, patient, session_date = Date.today)
    all_tasks = self.all(:order => 'sort_weight ASC')
    todays_encounters = patient.encounters.find_by_date(session_date)
    todays_encounter_types = todays_encounters.map{|e| e.type.name rescue ''}.uniq rescue []
    
    active_encounters = patient.encounters
    
    all_tasks.each do |task|
      # next if todays_encounters.map{ | e | e.name }.include?(task.encounter_type)
      # Is the task for this location?
      next unless task.location.blank? || task.location == '*' || location.name.match(/#{task.location}/)

      # Have we already run this task?
      # next if task.encounter_type.present? && todays_encounter_types.include?(task.encounter_type)

      # By default, we don't want to skip this task
      skip = false
 
      # Skip this task if this is a gender specific task and the gender does not match?
      # For example, if this is a female specific check and the patient is not female, we want to skip it
      skip = true if task.gender.present? && patient.person.gender != task.gender

      # Check for an observation made today with a specific value, skip this task unless that observation exists
      # For example, if this task is the art_clinician task we want to skip it unless REFER TO CLINICIAN = yes
      if task.has_obs_concept_id.present?
        if (task.has_obs_scope.blank? || task.has_obs_scope == 'TODAY')

=begin          
          obs = Observation.first(:conditions => [
              "encounter_id IN (?) AND concept_id = '?' AND (value_coded = '?' OR value_drug = '?' " + 
                "OR value_datetime = '?' OR value_numeric = '?' OR value_text = '?')",
              todays_encounters.map(&:encounter_id),
              task.has_obs_concept_id,
              task.has_obs_value_coded,
              task.has_obs_value_drug,
              task.has_obs_value_datetime,
              task.has_obs_value_numeric,
              task.has_obs_value_text])
=end
          obs = Observation.first(:conditions => [
              "encounter_id IN (?) AND concept_id = '?'",
              todays_encounters.map(&:encounter_id),
              task.has_obs_concept_id])
          
        end
        
        # Only the most recent obs
        # For example, if there are mutliple REFER TO CLINICIAN = yes, than only take the most recent one
        if (task.has_obs_scope == 'RECENT')
          o = patient.person.observations.recent(1).first(:conditions => 
              ['encounter_id IN (?) AND concept_id =? AND DATE(obs_datetime)=?', 
              todays_encounters.map(&:encounter_id), task.has_obs_concept_id,session_date])
          
          obs = 0 if (o.value_coded == task.has_obs_value_coded && o.value_drug == task.has_obs_value_drug &&
              o.value_datetime == task.has_obs_value_datetime && o.value_numeric == task.has_obs_value_numeric &&
              o.value_text == task.has_obs_value_text )
        end
          
        skip = true if obs.present?
      else
        next if todays_encounters.map{ | e | e.name }.include?(task.encounter_type)
      end

      if task.has_obs_value_drug && task.has_obs_scope == 'TODAY'
        obs = patient.orders.first(:conditions => ["concept_id = ? AND start_date = ?", 
            task.has_obs_value_drug, session_date])
        
        skip = true if obs.present?
      end
      
      # Only if this encounter type exists
      if (task.has_obs_scope == 'EXISTS')
        obs = patient.person.observations.first(:conditions => ['encounter_id IN (?)', 
            active_encounters.all(:conditions => ["encounter_type = ?", 
                EncounterType.find_by_name(task.encounter_type).id]).map(&:encounter_id)])        
        
        skip = true if obs.present?
      end
        
      # Check for a particular current order type, skip this task unless the order exists
      # For example, if this task is /dispensation/new we want to skip it if there is not already a drug order
      if task.has_order_type_id.present?
        skip = true unless Order.unfinished.first(:conditions => {:order_type_id => task.has_order_type_id}).present?
      end

      if task.has_encounter_type_today.present?
        enc = nil
        if todays_encounters.collect{|e|e.name}.include?(task.has_encounter_type_today)
          enc = task.has_encounter_type_today
        end
        skip = true if !enc.nil?
      end

      # Reverse the condition if the task wants the negative (for example, if the patient doesn't have a specific program yet, then run this task)
      skip = !skip if task.skip_if_has == 1

      # We need to skip this task for some reason
      next if skip

      # Nothing failed, this is the next task, lets replace any macros
      task.url = task.url.gsub(/\{patient\}/, "#{patient.patient_id}")
      task.url = task.url.gsub(/\{person\}/, "#{patient.person.person_id rescue nil}")
      task.url = task.url.gsub(/\{location\}/, "#{location.location_id rescue nil}")

      logger.debug "next_task: #{task.id} - #{task.description}"
      
      return task
    end
  end 
  
  def self.validate_task(patient, task, location, session_date = Date.today)
    #return task unless task.has_program_id == 1
    return task if task.encounter_type == 'REGISTRATION'

    #check if the latest HIV program is closed - if yes, the app should redirect the user to update state screen
    if patient.encounters.find_by_encounter_type(EncounterType.find_by_name('ART_INITIAL').id)
      latest_hiv_program = [] ; patient.patient_programs.collect{ | p |next unless p.program_id == 1 ; latest_hiv_program << p } 
      if latest_hiv_program.last.closed?
        task.url = '/patients/programs/{patient}' ; task.encounter_type = 'Program enrolment'
        return task
      end rescue nil
    end

    return task if task.url == "/patients/show/{patient}"

    art_encounters = ['ART_INITIAL','HIV RECEPTION','VITALS','HIV STAGING','ART VISIT','ART ADHERENCE','TREATMENT','DISPENSING']

    #if the following happens - that means the patient is a transfer in and the reception are trying to stage from the transfer in sheet
    if task.encounter_type == 'HIV STAGING' and location.name.match(/RECEPTION/i)
      return task 
    end

    #if the following happens - that means the patient was refered to see a clinician
    if task.description.match(/REFER/i) and location.name.match(/Clinician/i)
      return task 
    end

    if patient.encounters.find_by_encounter_type(EncounterType.find_by_name(art_encounters[0]).id).blank? and task.encounter_type != art_encounters[0]
      task.url = "/patients/summary?patient_id={patient}&skipped={encounter_type}" 
      task.url = task.url.gsub(/\{encounter_type\}/, "#{art_encounters[0].gsub(' ','_')}") 
      return task
    elsif patient.encounters.find_by_encounter_type(EncounterType.find_by_name(art_encounters[0]).id).blank? and task.encounter_type == art_encounters[0]
      return task
    end
    
    hiv_reception = Encounter.find(:first,
      :conditions =>["patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) = ?",
        patient.id,EncounterType.find_by_name(art_encounters[1]).id,session_date],
      :order =>'encounter_datetime DESC')

    if hiv_reception.blank? and task.encounter_type != art_encounters[1]
      task.url = "/patients/summary?patient_id={patient}&skipped={encounter_type}" 
      task.url = task.url.gsub(/\{encounter_type\}/, "#{art_encounters[1].gsub(' ','_')}") 
      return task
    elsif hiv_reception.blank? and task.encounter_type == art_encounters[1]
      return task
    end



    reception = Encounter.find(:first,:conditions =>["patient_id = ? AND DATE(encounter_datetime) = ? AND encounter_type = ?",
        patient.id,session_date,EncounterType.find_by_name(art_encounters[1]).id]).observations.to_s rescue ''
    
    if reception.match(/PATIENT PRESENT FOR CONSULTATION: YES/)
      vitals = Encounter.find(:first,
        :conditions =>["patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) = ?",
          patient.id,EncounterType.find_by_name(art_encounters[2]).id,session_date],
        :order =>'encounter_datetime DESC')

      if vitals.blank? and task.encounter_type != art_encounters[2]
        task.url = "/patients/summary?patient_id={patient}&skipped={encounter_type}" 
        task.url = task.url.gsub(/\{encounter_type\}/, "#{art_encounters[2].gsub(' ','_')}") 
        return task
      elsif vitals.blank? and task.encounter_type == art_encounters[2]
        return task
      end
    end


    if patient.encounters.find_by_encounter_type(EncounterType.find_by_name(art_encounters[3]).id).blank? and task.encounter_type != art_encounters[3]
      task.url = "/patients/summary?patient_id={patient}&skipped={encounter_type}" 
      task.url = task.url.gsub(/\{encounter_type\}/, "#{art_encounters[3].gsub(' ','_')}") 
      return task
    elsif patient.encounters.find_by_encounter_type(EncounterType.find_by_name(art_encounters[3]).id).blank? and task.encounter_type == art_encounters[3]
      return task
    end

    art_visit = Encounter.find(:first,
      :conditions =>["patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) = ?",
        patient.id,EncounterType.find_by_name(art_encounters[4]).id,session_date],
      :order =>'encounter_datetime DESC',:limit => 1)

    if art_visit.blank? and task.encounter_type != art_encounters[4]
      task.url = "/patients/summary?patient_id={patient}&skipped={encounter_type}" 
      task.url = task.url.gsub(/\{encounter_type\}/, "#{art_encounters[4].gsub(' ','_')}") 
      return task
    elsif art_visit.blank? and task.encounter_type == art_encounters[4]
      return task
    end

    unless patient.drug_given_before(session_date).blank?
      art_adherance = Encounter.find(:first,
        :conditions =>["patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) = ?",
          patient.id,EncounterType.find_by_name(art_encounters[5]).id,session_date],
        :order =>'encounter_datetime DESC',:limit => 1)
      
      if art_adherance.blank? and task.encounter_type != art_encounters[5]
        task.url = "/patients/summary?patient_id={patient}&skipped={encounter_type}" 
        task.url = task.url.gsub(/\{encounter_type\}/, "#{art_encounters[5].gsub(' ','_')}") 
        return task
      elsif art_adherance.blank? and task.encounter_type == art_encounters[5]
        return task
      end
    end

    if patient.prescribe_arv_this_visit(session_date)
      art_treatment = Encounter.find(:first,
        :conditions =>["patient_id = ? AND encounter_type = ? AND DATE(encounter_datetime) = ?",
          patient.id,EncounterType.find_by_name(art_encounters[6]).id,session_date],
        :order =>'encounter_datetime DESC',:limit => 1)
      if art_treatment.blank? and task.encounter_type != art_encounters[6]
        task.url = "/patients/summary?patient_id={patient}&skipped={encounter_type}" 
        task.url = task.url.gsub(/\{encounter_type\}/, "#{art_encounters[6].gsub(' ','_')}") 
        return task
      elsif art_treatment.blank? and task.encounter_type == art_encounters[6]
        return task
      end
    end

    task
  end 
end
